import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

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
  final List<String> warnings = <String>[];
  final List<DependencyFloor> resolvedFloorMetadata = <DependencyFloor>[];

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

    final resolvedSiblings =
        localSiblings ?? PubspecHelper.findLocalSiblings(sourcePackagePath);

    final staging = SyntheticStaging._(
      sourcePackagePath: sourcePackagePath,
      pubspec: pubspec,
      stagingDir: tempDir,
      localSiblings: resolvedSiblings,
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
    var searchDir = Directory(sourcePackagePath);
    File? optionsFile;

    // Look in package root first, then ascend up to repo root
    while (true) {
      final candidate = File(p.join(searchDir.path, 'analysis_options.yaml'));
      if (candidate.existsSync()) {
        optionsFile = candidate;
        break;
      }
      final parent = searchDir.parent;
      if (parent.path == searchDir.path) break;
      searchDir = parent;
    }

    if (optionsFile != null) {
      final raw = optionsFile.readAsStringSync();
      // Remove package: includes that reference dev_dependencies (e.g. lints)
      final sanitizedLines = <String>[];
      for (final line in raw.split('\n')) {
        if (line.trim().startsWith('include: package:')) {
          sanitizedLines.add(
            '# [lower_bound stripped include: ${line.trim()}]',
          );
        } else {
          sanitizedLines.add(line);
        }
      }
      File(
        p.join(stagingDir.path, 'analysis_options.yaml'),
      ).writeAsStringSync(sanitizedLines.join('\n'));
    }
  }

  /// Writes a synthetic pubspec.yaml into the staging directory.
  ///
  /// - Strips `dev_dependencies` completely.
  /// - Strips `resolution: workspace` completely so dependencies resolve from
  ///   pub.dev.
  /// - Pins external dependencies to exact declared floors if [pinLowerBounds]
  ///   is true.
  /// - Links unreleased `-wip` local siblings via path overrides and emits soft
  ///   warnings.
  void writePubspec({
    bool pinLowerBounds = true,
    Set<String> excludeOverrides = const {},
  }) {
    warnings.clear();
    resolvedFloorMetadata.clear();

    final buffer = StringBuffer();
    buffer.writeln('name: ${pubspec.name}');
    buffer.writeln('publish_to: none');
    buffer.writeln();
    buffer.writeln('environment:');
    buffer.writeln('  sdk: \'${pubspec.sdkConstraint}\'');
    buffer.writeln();

    if (pubspec.rawDependencies.isNotEmpty) {
      buffer.writeln('dependencies:');
      for (final entry in pubspec.rawDependencies.entries) {
        buffer.writeln('  ${entry.key}: \'${entry.value}\'');
      }
      buffer.writeln();
    }

    final exactVersionOverrides = <String, String>{};
    final pathOverrides = <String, String>{};

    for (final dep in pubspec.dependencies) {
      final sibling = localSiblings[dep.name];
      final isUnreleasedWipSibling =
          sibling != null && (sibling.isWip || sibling.isPublishToNone);

      if (isUnreleasedWipSibling) {
        // Local -wip sibling fallback
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
      } else {
        resolvedFloorMetadata.add(
          DependencyFloor(
            name: dep.name,
            declaredConstraint: dep.declaredConstraint,
            lowerBound: dep.lowerBound,
            isLocalPathOverride: false,
          ),
        );

        if (pinLowerBounds &&
            !excludeOverrides.contains(dep.name) &&
            dep.lowerBound != null) {
          exactVersionOverrides[dep.name] = dep.lowerBound.toString();
        }
      }
    }

    if (exactVersionOverrides.isNotEmpty || pathOverrides.isNotEmpty) {
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

    final stagedPubspec = File(p.join(stagingDir.path, 'pubspec.yaml'));
    stagedPubspec.writeAsStringSync(buffer.toString());
  }

  /// Reads resolved dependency versions from the generated package_config.json.
  Map<String, String> readResolvedVersions() {
    final configFile = File(
      p.join(stagingDir.path, '.dart_tool', 'package_config.json'),
    );
    if (!configFile.existsSync()) return {};

    try {
      final content = configFile.readAsStringSync();
      final json = jsonDecode(content);
      if (json is! Map<String, dynamic>) return {};
      final packages = json['packages'];
      if (packages is! List) return {};

      final result = <String, String>{};
      for (final pkg in packages) {
        if (pkg is Map<String, dynamic>) {
          final name = pkg['name'] as String?;
          final rootUri = pkg['rootUri'] as String?;
          if (name != null && rootUri != null) {
            // Check if rootUri is a pub cache path containing version
            final match = RegExp(r'-(\d+\.\d+\.\d+.*)$').firstMatch(rootUri);
            if (match != null) {
              result[name] = match.group(1)!;
              continue;
            }

            // If it's a file URI or path, try reading pubspec from directory
            try {
              final uri = Uri.parse(rootUri);
              final String packageDir;
              if (uri.isAbsolute && uri.scheme == 'file') {
                packageDir = uri.toFilePath();
              } else {
                packageDir = p.normalize(
                  p.join(stagingDir.path, '.dart_tool', rootUri),
                );
              }
              final pubspecFile = File(p.join(packageDir, 'pubspec.yaml'));
              if (pubspecFile.existsSync()) {
                final pubspecParsed = PubspecHelper.parse(packageDir);
                if (pubspecParsed.rawVersion != null) {
                  result[name] = pubspecParsed.rawVersion!;
                }
              }
            } catch (_) {}
          }
        }
      }
      return result;
    } catch (_) {
      return {};
    }
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
