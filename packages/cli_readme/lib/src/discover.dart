import 'dart:io';

import 'package:path/path.dart' as p;
// ignore: implementation_imports
import 'package:test_api/src/backend/invoker.dart';
import 'package:yaml/yaml.dart';

import 'models.dart';

/// Discovers package configuration and default targets.
class PackageContext {
  final String packageDirectory;
  final String packageName;
  final String readmePath;
  final List<CliTarget> defaultTargets;

  const PackageContext({
    required this.packageDirectory,
    required this.packageName,
    required this.readmePath,
    required this.defaultTargets,
  });

  /// Discovers package context starting from [workingDir] and optional
  /// [packageRelativeDirectory].
  static PackageContext discover({
    String? workingDir,
    String? packageRelativeDirectory,
    String? readmePath,
    List<CliTarget>? customTargets,
  }) {
    final dir = _resolvePackageDirectory(workingDir, packageRelativeDirectory);
    final pubspecYaml = _readPubspecYaml(dir);
    final pkgName = pubspecYaml['name'] as String? ?? 'app';

    final resolvedReadmePath = readmePath != null
        ? (p.isAbsolute(readmePath) ? readmePath : p.join(dir, readmePath))
        : p.join(dir, 'README.md');

    final targets =
        customTargets ?? _discoverTargets(dir, pkgName, pubspecYaml);

    if (targets.isEmpty) {
      throw StateError(
        'No CLI targets found in "$dir". '
        'Ensure "executables" are declared in pubspec.yaml, '
        'a binary exists in "bin/", or pass explicit targets.',
      );
    }

    return PackageContext(
      packageDirectory: dir,
      packageName: pkgName,
      readmePath: resolvedReadmePath,
      defaultTargets: targets,
    );
  }

  static String _resolvePackageDirectory(
    String? workingDir,
    String? packageRelativeDirectory,
  ) {
    var dir = workingDir != null
        ? Directory(workingDir).resolveSymbolicLinksSync()
        : Directory.current.resolveSymbolicLinksSync();

    if (packageRelativeDirectory != null &&
        packageRelativeDirectory.isNotEmpty) {
      return p.normalize(p.join(dir, packageRelativeDirectory));
    }

    if (workingDir == null && _isWorkspaceRoot(dir)) {
      final inferred = _inferPackageFromTestRunner(dir);
      if (inferred != null) return inferred;
    }

    return dir;
  }

  static bool _isWorkspaceRoot(String dir) {
    final pubspecFile = File(p.join(dir, 'pubspec.yaml'));
    if (!pubspecFile.existsSync()) return false;
    final yaml = loadYaml(pubspecFile.readAsStringSync()) as Map?;
    return yaml != null && yaml.containsKey('workspace');
  }

  static Map _readPubspecYaml(String dir) {
    final pubspecFile = File(p.join(dir, 'pubspec.yaml'));
    if (!pubspecFile.existsSync()) {
      throw StateError(
        'Could not locate pubspec.yaml in $dir. '
        'Ensure the command is run from a Dart package root or specify '
        'packageRelativeDirectory.',
      );
    }
    return loadYaml(pubspecFile.readAsStringSync()) as Map;
  }

  static String? _inferPackageFromTestRunner(String workspaceRoot) {
    try {
      final suitePath = Invoker.current?.liveTest.suite.path;
      if (suitePath == null || suitePath.isEmpty) return null;

      final absPath = p.isAbsolute(suitePath)
          ? suitePath
          : p.join(workspaceRoot, suitePath);

      var parent = Directory(p.dirname(absPath));
      while (parent.path != workspaceRoot && parent.path.length > 3) {
        if (File(p.join(parent.path, 'pubspec.yaml')).existsSync()) {
          return parent.path;
        }
        final next = parent.parent;
        if (next.path == parent.path) break;
        parent = next;
      }
    } catch (_) {
      // Ignored if not running inside package:test
    }
    return null;
  }

  static List<CliTarget> _discoverTargets(
    String dir,
    String pkgName,
    Map pubspecYaml,
  ) =>
      _targetsFromExecutables(pubspecYaml) ??
      _targetFromDefaultBin(dir, pkgName) ??
      _targetsFromBinDirectory(dir, pkgName) ??
      const [];

  static List<CliTarget>? _targetsFromExecutables(Map pubspecYaml) {
    final executables = pubspecYaml['executables'] as Map?;
    if (executables == null || executables.isEmpty) return null;

    final isSingle = executables.length == 1;
    final targets = <CliTarget>[];

    for (final entry in executables.entries) {
      final execName = entry.key.toString();
      final scriptValue = entry.value?.toString();
      final scriptRelPath = (scriptValue != null && scriptValue.isNotEmpty)
          ? 'bin/$scriptValue.dart'
          : 'bin/$execName.dart';

      targets.add(
        CliTarget.executable(
          id: isSingle ? '' : execName,
          executablePath: scriptRelPath,
          commandName: execName,
        ),
      );
    }
    return targets;
  }

  static List<CliTarget>? _targetFromDefaultBin(String dir, String pkgName) {
    final defaultBin = p.join(dir, 'bin', '$pkgName.dart');
    if (!File(defaultBin).existsSync()) return null;

    return [
      CliTarget.executable(
        id: '',
        executablePath: 'bin/$pkgName.dart',
        commandName: pkgName,
      ),
    ];
  }

  static List<CliTarget>? _targetsFromBinDirectory(String dir, String pkgName) {
    final binDir = Directory(p.join(dir, 'bin'));
    if (!binDir.existsSync()) return null;

    final dartFiles = binDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList();

    if (dartFiles.isEmpty) return null;

    if (dartFiles.length == 1) {
      final rel = p.relative(dartFiles.first.path, from: dir);
      return [
        CliTarget.executable(id: '', executablePath: rel, commandName: pkgName),
      ];
    }

    return [
      for (final f in dartFiles)
        CliTarget.executable(
          id: p.basenameWithoutExtension(f.path),
          executablePath: p.relative(f.path, from: dir),
          commandName: p.basenameWithoutExtension(f.path),
        ),
    ];
  }
}
