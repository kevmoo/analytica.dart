import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'github_actions.dart';
import 'models.dart';
import 'pubspec_helper.dart';

/// Manages an isolated synthetic package directory for lower-bound
/// verification.
class SyntheticStaging {
  final String sourcePackagePath;
  final ParsedPubspec pubspec;
  final Directory stagingDir;
  final Map<String, LocalSibling> localSiblings;
  final List<String> warnings = [];
  final List<DependencyFloor> resolvedFloorMetadata = [];

  SyntheticStaging._({
    required this.sourcePackagePath,
    required this.pubspec,
    required this.stagingDir,
    required this.localSiblings,
  });

  /// Creates an isolated staging environment for [sourcePackagePath].
  static SyntheticStaging create({
    required String sourcePackagePath,
    required ParsedPubspec pubspec,
    Directory? baseTempDir,
    Map<String, LocalSibling>? localSiblings,
  }) {
    final parent = baseTempDir ?? Directory.systemTemp;
    final tempDir = parent.createTempSync('lower_bound_staged_');
    final siblings =
        localSiblings ?? PubspecHelper.findLocalSiblings(sourcePackagePath);

    final staging = SyntheticStaging._(
      sourcePackagePath: sourcePackagePath,
      pubspec: pubspec,
      stagingDir: tempDir,
      localSiblings: siblings,
    );

    staging._setupDirectory();
    return staging;
  }

  void _setupDirectory() {
    // 1. Copy lib directory using absolute path
    final sourceLib = Directory(p.join(sourcePackagePath, 'lib')).absolute;
    if (sourceLib.existsSync()) {
      _copyDirectory(sourceLib, Directory(p.join(stagingDir.path, 'lib')));
    }

    // 2. Copy bin directory if present
    final sourceBin = Directory(p.join(sourcePackagePath, 'bin')).absolute;
    if (sourceBin.existsSync()) {
      _copyDirectory(sourceBin, Directory(p.join(stagingDir.path, 'bin')));
    }

    // 3. Copy analysis_options.yaml if present (or look up parent hierarchy)
    _copyAnalysisOptions();
  }

  void _copyAnalysisOptions() {
    final optionsFile = _findAnalysisOptionsFile();
    if (optionsFile == null) return;

    final raw = optionsFile.readAsStringSync();
    final sanitizedLines = <String>[];
    for (final line in raw.split('\n')) {
      if (line.trim().startsWith('include: package:')) {
        sanitizedLines.add('# [lower_bound stripped include: ${line.trim()}]');
      } else {
        sanitizedLines.add(line);
      }
    }
    File(
      p.join(stagingDir.path, 'analysis_options.yaml'),
    ).writeAsStringSync(sanitizedLines.join('\n'));
  }

  File? _findAnalysisOptionsFile() {
    var searchDir = Directory(sourcePackagePath);
    while (true) {
      final candidate = File(p.join(searchDir.path, 'analysis_options.yaml'));
      if (candidate.existsSync()) return candidate;
      final parent = searchDir.parent;
      if (parent.path == searchDir.path) break;
      searchDir = parent;
    }
    return null;
  }

  /// Writes a synthetic pubspec.yaml into the staging directory.
  void writePubspec({
    bool pinLowerBounds = true,
    Set<String> excludeOverrides = const {},
  }) {
    warnings.clear();
    resolvedFloorMetadata.clear();

    final buffer = StringBuffer();
    _writeHeader(buffer);
    _writeDependencies(buffer);

    final (:exactVersionOverrides, :pathOverrides) = _collectOverrides(
      pinLowerBounds: pinLowerBounds,
      excludeOverrides: excludeOverrides,
    );

    _writeOverrides(buffer, exactVersionOverrides, pathOverrides);

    File(
      p.join(stagingDir.path, 'pubspec.yaml'),
    ).writeAsStringSync(buffer.toString());
  }

  void _writeHeader(StringBuffer buffer) {
    buffer.writeln('name: ${pubspec.name}');
    buffer.writeln('publish_to: none');
    buffer.writeln();
    buffer.writeln('environment:');
    buffer.writeln('  sdk: \'${pubspec.sdkConstraint}\'');
    buffer.writeln();
  }

  void _writeDependencies(StringBuffer buffer) {
    if (pubspec.rawDependencies.isEmpty) return;
    buffer.writeln('dependencies:');
    for (final entry in pubspec.rawDependencies.entries) {
      buffer.writeln('  ${entry.key}: \'${entry.value}\'');
    }
    buffer.writeln();
  }

  ({
    Map<String, String> exactVersionOverrides,
    Map<String, String> pathOverrides,
  })
  _collectOverrides({
    required bool pinLowerBounds,
    required Set<String> excludeOverrides,
  }) {
    final exactVersionOverrides = <String, String>{};
    final pathOverrides = <String, String>{};

    for (final dep in pubspec.dependencies) {
      final sibling = localSiblings[dep.name];
      if (_isUnreleasedWipSibling(sibling)) {
        _handleWipSibling(dep, sibling!, pathOverrides);
      } else if (pinLowerBounds && !excludeOverrides.contains(dep.name)) {
        _handleExactFloorOverride(dep, exactVersionOverrides);
      } else {
        resolvedFloorMetadata.add(dep);
      }
    }

    return (
      exactVersionOverrides: exactVersionOverrides,
      pathOverrides: pathOverrides,
    );
  }

  bool _isUnreleasedWipSibling(LocalSibling? sibling) {
    return sibling != null && (sibling.isWip || sibling.isPublishToNone);
  }

  void _handleWipSibling(
    DependencyFloor dep,
    LocalSibling sibling,
    Map<String, String> pathOverrides,
  ) {
    pathOverrides[dep.name] = sibling.path;
    final rawVer = sibling.rawVersion ?? 'unreleased';
    final warningMsg =
        'Package \'${pubspec.name}\' depends on unreleased local sibling '
        '\'${dep.name}\' ($rawVer). Linked via local path override for '
        'lower-bound validation.';
    warnings.add(warningMsg);
    emitGitHubWarning(
      warningMsg,
      file: p.join(sourcePackagePath, 'pubspec.yaml'),
      title: 'Unreleased Local Sibling Dependency',
    );

    resolvedFloorMetadata.add(
      DependencyFloor(
        name: dep.name,
        declaredConstraint: dep.declaredConstraint,
        lowerBound: dep.lowerBound,
        isLocalPathOverride: true,
        localPath: sibling.path,
        localVersion: sibling.rawVersion,
      ),
    );
  }

  void _handleExactFloorOverride(
    DependencyFloor dep,
    Map<String, String> exactVersionOverrides,
  ) {
    if (dep.lowerBound != null) {
      exactVersionOverrides[dep.name] = dep.lowerBound.toString();
    }
    resolvedFloorMetadata.add(dep);
  }

  void _writeOverrides(
    StringBuffer buffer,
    Map<String, String> exactVersionOverrides,
    Map<String, String> pathOverrides,
  ) {
    if (exactVersionOverrides.isEmpty && pathOverrides.isEmpty) return;

    buffer.writeln('dependency_overrides:');
    for (final entry in exactVersionOverrides.entries) {
      buffer.writeln('  ${entry.key}: \'${entry.value}\'');
    }
    for (final entry in pathOverrides.entries) {
      buffer.writeln('  ${entry.key}:');
      buffer.writeln('    path: \'${entry.value}\'');
    }
    buffer.writeln();
  }

  /// Reads resolved dependency versions from the generated package_config.json.
  Map<String, String> readResolvedVersions() {
    final configFile = File(
      p.join(stagingDir.path, '.dart_tool', 'package_config.json'),
    );
    if (!configFile.existsSync()) return {};

    try {
      final json = loadYaml(configFile.readAsStringSync());
      if (json is! YamlMap) return {};
      final packages = json['packages'];
      if (packages is! YamlList) return {};

      final result = <String, String>{};
      for (final pkg in packages) {
        if (pkg is YamlMap) {
          final name = pkg['name'] as String?;
          final rootUri = pkg['rootUri'] as String?;
          if (name != null && rootUri != null) {
            final version = _extractPackageVersion(name, rootUri);
            if (version != null) {
              result[name] = version;
            }
          }
        }
      }
      return result;
    } catch (_) {
      return {};
    }
  }

  String? _extractPackageVersion(String name, String rootUri) {
    final match = RegExp(r'-(\d+\.\d+\.\d+.*)$').firstMatch(rootUri);
    if (match != null) {
      return match.group(1);
    }
    final sibling = localSiblings[name];
    if (sibling?.rawVersion != null) {
      return sibling!.rawVersion;
    }
    return null;
  }

  void dispose() {
    if (stagingDir.existsSync()) {
      try {
        stagingDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  void _copyDirectory(Directory source, Directory destination) {
    destination.createSync(recursive: true);
    for (final entity in source.listSync(recursive: false)) {
      final targetPath = p.join(destination.path, p.basename(entity.path));
      if (entity is Directory) {
        _copyDirectory(entity, Directory(targetPath));
      } else if (entity is File) {
        entity.copySync(targetPath);
      }
    }
  }
}
