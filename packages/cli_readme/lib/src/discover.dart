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
    var dir = workingDir != null
        ? Directory(workingDir).resolveSymbolicLinksSync()
        : Directory.current.resolveSymbolicLinksSync();

    if (packageRelativeDirectory != null &&
        packageRelativeDirectory.isNotEmpty) {
      dir = p.normalize(p.join(dir, packageRelativeDirectory));
    } else if (workingDir == null) {
      // Check if current directory is a workspace root
      final currentPubspec = File(p.join(dir, 'pubspec.yaml'));
      if (currentPubspec.existsSync()) {
        final yaml = loadYaml(currentPubspec.readAsStringSync()) as Map?;
        if (yaml != null && yaml.containsKey('workspace')) {
          final inferredPkgDir = _inferPackageFromTestRunner(dir);
          if (inferredPkgDir != null) {
            dir = inferredPkgDir;
          }
        }
      }
    }

    final pubspecFile = File(p.join(dir, 'pubspec.yaml'));
    if (!pubspecFile.existsSync()) {
      throw StateError(
        'Could not locate pubspec.yaml in $dir. '
        'Ensure the command is run from a Dart package root or specify '
        'packageRelativeDirectory.',
      );
    }

    final pubspecYaml = loadYaml(pubspecFile.readAsStringSync()) as Map;
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

  static String? _inferPackageFromTestRunner(String workspaceRoot) {
    try {
      final suitePath = Invoker.current?.liveTest.suite.path;
      if (suitePath != null && suitePath.isNotEmpty) {
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
  ) {
    final targets = <CliTarget>[];
    final executables = pubspecYaml['executables'] as Map?;

    if (executables != null && executables.isNotEmpty) {
      final isSingle = executables.length == 1;
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

    // Check bin/<pkgName>.dart
    final defaultBin = p.join(dir, 'bin', '$pkgName.dart');
    if (File(defaultBin).existsSync()) {
      targets.add(
        CliTarget.executable(
          id: '',
          executablePath: 'bin/$pkgName.dart',
          commandName: pkgName,
        ),
      );
      return targets;
    }

    // Check all files in bin/
    final binDir = Directory(p.join(dir, 'bin'));
    if (binDir.existsSync()) {
      final dartFiles = binDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList();

      if (dartFiles.length == 1) {
        final rel = p.relative(dartFiles.first.path, from: dir);
        targets.add(
          CliTarget.executable(
            id: '',
            executablePath: rel,
            commandName: pkgName,
          ),
        );
      } else if (dartFiles.length > 1) {
        for (final f in dartFiles) {
          final rel = p.relative(f.path, from: dir);
          final base = p.basenameWithoutExtension(f.path);
          targets.add(
            CliTarget.executable(
              id: base,
              executablePath: rel,
              commandName: base,
            ),
          );
        }
      }
    }

    return targets;
  }
}
