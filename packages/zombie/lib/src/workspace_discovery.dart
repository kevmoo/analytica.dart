import 'dart:io';

import 'package:analytica/analyzer.dart';
import 'package:analytica/sdk_discovery.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// Container for companion roots discovered across sibling packages in a
/// workspace.
class DiscoveredCompanionRoots {
  /// File paths belonging to companion production entrypoints (`lib/**`).
  final List<String> productionRoots;

  /// File paths belonging to companion test suites (`test/**`).
  final List<String> testRoots;

  const DiscoveredCompanionRoots({
    this.productionRoots = const [],
    this.testRoots = const [],
  });

  /// Whether no companion roots were discovered.
  bool get isEmpty => productionRoots.isEmpty && testRoots.isEmpty;

  /// Whether companion roots were discovered.
  bool get isNotEmpty => !isEmpty;
}

/// Discovers companion consumer packages in an enclosing workspace or
/// repository that depend on the analyzed target package.
class WorkspaceConsumerDiscovery {
  /// Default directory names excluded from workspace consumer traversal.
  static const Set<String> defaultExcludedDirectories = {
    '.git',
    '.dart_tool',
    'build',
    'out',
    'node_modules',
    'third_party',
    'example',
    'examples',
  };

  /// Internal package source directories that should not be searched for
  /// nested child packages once a package root is identified.
  static const Set<String> _packageInternalDirs = {
    'lib',
    'test',
    'bin',
    'tool',
    'benchmark',
    'web',
    'doc',
    'src',
    'ios',
    'android',
    'macos',
    'windows',
    'linux',
  };

  /// Maximum directory depth to search from the workspace root.
  final int maxDepth;

  /// Directory names excluded from traversal.
  final Set<String> excludedDirectories;

  const WorkspaceConsumerDiscovery({
    this.maxDepth = 4,
    this.excludedDirectories = defaultExcludedDirectories,
  });

  /// Locates the enclosing workspace or repository root by searching upward
  /// from [packagePath] for `.git`, `DEPS`, `.gclient`, or `pubspec.yaml`
  /// with a `workspace:` key.
  String? findWorkspaceRoot(String packagePath) {
    var dir = Directory(p.normalize(p.absolute(packagePath)));
    while (true) {
      if (_isWorkspaceRoot(dir)) {
        return dir.path;
      }
      final parent = dir.parent;
      if (parent.path == dir.path) {
        break;
      }
      dir = parent;
    }
    return null;
  }

  /// Discovers companion consumer packages referencing [targetPackageName]
  /// (or the package at [packagePath]) within the workspace.
  DiscoveredCompanionRoots discoverConsumers({
    required String packagePath,
    String? targetPackageName,
    String? workspaceRoot,
  }) {
    final absPackagePath = p.normalize(p.absolute(packagePath));
    final root = workspaceRoot ?? findWorkspaceRoot(absPackagePath);
    if (root == null) {
      return const DiscoveredCompanionRoots();
    }

    final effectiveTargetName =
        targetPackageName ?? _readPackageName(absPackagePath);
    if (effectiveTargetName == null) {
      return const DiscoveredCompanionRoots();
    }

    final productionRoots = <String>[];
    final testRoots = <String>[];

    _scanDirectory(
      dir: Directory(root),
      depth: 0,
      targetPackagePath: absPackagePath,
      targetPackageName: effectiveTargetName,
      productionRoots: productionRoots,
      testRoots: testRoots,
    );

    return DiscoveredCompanionRoots(
      productionRoots: productionRoots,
      testRoots: testRoots,
    );
  }

  void _scanDirectory({
    required Directory dir,
    required int depth,
    required String targetPackagePath,
    required String targetPackageName,
    required List<String> productionRoots,
    required List<String> testRoots,
  }) {
    if (depth > maxDepth) return;
    if (!dir.existsSync()) return;

    final dirPath = p.normalize(p.absolute(dir.path));
    final isTargetPkg = p.equals(dirPath, targetPackagePath);
    var isSiblingPkg = false;

    if (!isTargetPkg) {
      final pubspecFile = File(p.join(dirPath, 'pubspec.yaml'));
      if (pubspecFile.existsSync()) {
        isSiblingPkg = true;
        _inspectSiblingPackage(
          packageDir: dir,
          pubspecFile: pubspecFile,
          targetPackageName: targetPackageName,
          productionRoots: productionRoots,
          testRoots: testRoots,
        );
      }
    }

    if (depth < maxDepth) {
      try {
        final entities = dir.listSync(followLinks: false);
        for (final entity in entities) {
          if (entity is! Directory) continue;
          final baseName = p.basename(entity.path);
          if (_isExcludedDirectory(baseName)) continue;
          if (isSiblingPkg && _packageInternalDirs.contains(baseName)) {
            continue;
          }
          if (p.equals(
            p.normalize(p.absolute(entity.path)),
            targetPackagePath,
          )) {
            continue;
          }

          _scanDirectory(
            dir: entity,
            depth: depth + 1,
            targetPackagePath: targetPackagePath,
            targetPackageName: targetPackageName,
            productionRoots: productionRoots,
            testRoots: testRoots,
          );
        }
      } catch (_) {}
    }
  }

  void _inspectSiblingPackage({
    required Directory packageDir,
    required File pubspecFile,
    required String targetPackageName,
    required List<String> productionRoots,
    required List<String> testRoots,
  }) {
    final dynamic doc;
    try {
      final content = pubspecFile.readAsStringSync();
      doc = loadYaml(content);
    } catch (_) {
      return;
    }
    if (doc is! Map) return;

    final dependencies = doc['dependencies'];
    final devDependencies = doc['dev_dependencies'];
    final dependencyOverrides = doc['dependency_overrides'];

    var referencesTarget = false;
    if (dependencies is Map && dependencies.containsKey(targetPackageName)) {
      referencesTarget = true;
    }
    if (devDependencies is Map &&
        devDependencies.containsKey(targetPackageName)) {
      referencesTarget = true;
    }
    if (dependencyOverrides is Map &&
        dependencyOverrides.containsKey(targetPackageName)) {
      referencesTarget = true;
    }

    if (!referencesTarget) return;

    // Ensure sibling package has a valid .dart_tool/package_config.json before ingesting
    if (!hasPackageConfig(packageDir.path) &&
        !hasEnclosingPackageConfig(packageDir.path)) {
      return;
    }

    // Dual Root Ingestion: sibling lib/ -> productionRoots, sibling test/ -> testRoots
    final libDir = Directory(p.join(packageDir.path, 'lib'));
    if (libDir.existsSync()) {
      _collectDartFiles(libDir, productionRoots);
    }

    final testDir = Directory(p.join(packageDir.path, 'test'));
    if (testDir.existsSync()) {
      _collectDartFiles(testDir, testRoots);
    }
  }

  void _collectDartFiles(Directory dir, List<String> destination) {
    try {
      for (final entity in dir.listSync(recursive: true, followLinks: false)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final relPath = p.relative(entity.path, from: dir.path);
        final segments = p.split(relPath);
        if (segments.contains('.git') || segments.contains('.dart_tool')) {
          continue;
        }
        final normalized = p.normalize(p.absolute(entity.path));
        destination.add(normalized);
      }
    } catch (_) {}
  }

  bool _isWorkspaceRoot(Directory dir) {
    if (Directory(p.join(dir.path, '.git')).existsSync() ||
        File(p.join(dir.path, '.git')).existsSync()) {
      return true;
    }
    if (File(p.join(dir.path, 'DEPS')).existsSync()) {
      return true;
    }
    if (File(p.join(dir.path, '.gclient')).existsSync()) {
      return true;
    }
    final pubspecFile = File(p.join(dir.path, 'pubspec.yaml'));
    if (pubspecFile.existsSync()) {
      try {
        final content = pubspecFile.readAsStringSync();
        final doc = loadYaml(content);
        if (doc is Map &&
            doc.containsKey('workspace') &&
            doc['workspace'] != null) {
          return true;
        }
      } catch (_) {}
    }
    return false;
  }

  bool _isExcludedDirectory(String dirName) {
    for (final pattern in excludedDirectories) {
      if (pattern == dirName) return true;
      if (pattern == '$dirName/**' || pattern == '$dirName/*') return true;
      final clean = pattern.replaceAll('/**', '').replaceAll('/*', '');
      if (clean == dirName) return true;
      if (WildcardPattern(pattern).matches(dirName)) return true;
    }
    return false;
  }

  String? _readPackageName(String packagePath) {
    final pubspecFile = File(p.join(packagePath, 'pubspec.yaml'));
    if (!pubspecFile.existsSync()) return null;
    try {
      final content = pubspecFile.readAsStringSync();
      final doc = loadYaml(content);
      if (doc is Map && doc['name'] is String) {
        return doc['name'] as String;
      }
    } catch (_) {}
    return null;
  }
}
