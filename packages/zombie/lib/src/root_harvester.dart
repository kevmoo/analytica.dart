import 'dart:io';

import 'package:analytica/sdk_discovery.dart';
import 'package:path/path.dart' as p;

import 'models.dart';

/// Role and classification of a Dart source file within a package layout.
enum FileRole {
  /// Public API entrypoint/interface (`lib/**` excluding `lib/src/`).
  publicLib,

  /// Internal implementation source (`lib/src/**`).
  internalSrc,

  /// CLI binary entrypoint (`bin/**`).
  executable,

  /// Sample app or documentation demo (`example/**`).
  demonstration,

  /// Utility or auxiliary entrypoint (`tool/**`, `benchmark/**`, `web/**`).
  auxiliary,

  /// Test suite (`test/**`, `integration_test/**`, `test_driver/**`).
  test,

  /// Other files outside standard topologies.
  other;

  /// Whether declarations in this file are candidates for zombie detection.
  bool get isCandidateTarget => switch (this) {
    internalSrc || executable || auxiliary => true,
    _ => false,
  };
}

/// Discovered package topology and file listing.
class PackageTopology {
  final String packagePath;
  final String packageName;
  final List<String> publicLibFiles;
  final List<String> internalSrcFiles;
  final List<String> executableFiles;
  final List<String> demonstrationFiles;
  final List<String> auxiliaryFiles;
  final List<String> testFiles;
  final Set<String> frameworkRoots;

  const PackageTopology({
    required this.packagePath,
    required this.packageName,
    required this.publicLibFiles,
    required this.internalSrcFiles,
    required this.executableFiles,
    required this.demonstrationFiles,
    required this.auxiliaryFiles,
    required this.testFiles,
    this.frameworkRoots = const {},
  });

  /// Deprecated alias for [frameworkRoots].
  @Deprecated('Use frameworkRoots instead')
  Set<String> get builderFactoryNames => frameworkRoots;

  /// Deprecated alias for [frameworkRoots].
  @Deprecated('Use frameworkRoots instead')
  Set<String> get pluginClassNames => frameworkRoots;

  /// All scanned Dart files.
  List<String> get allFiles => [
    ...publicLibFiles,
    ...internalSrcFiles,
    ...executableFiles,
    ...demonstrationFiles,
    ...auxiliaryFiles,
    ...testFiles,
  ];

  /// Resolves the role of a given [relativeFilePath].
  FileRole roleOf(String relativeFilePath) {
    final normalized = p.normalize(relativeFilePath);
    if (testFiles.contains(normalized)) {
      return FileRole.test;
    }
    if (normalized.startsWith('lib/src/') ||
        normalized.startsWith('lib/src\\')) {
      return FileRole.internalSrc;
    }
    if (normalized.startsWith('lib/') || normalized.startsWith('lib\\')) {
      return FileRole.publicLib;
    }
    if (normalized.startsWith('bin/') || normalized.startsWith('bin\\')) {
      return FileRole.executable;
    }
    if (normalized.startsWith('example/') ||
        normalized.startsWith('example\\')) {
      return FileRole.demonstration;
    }
    if (normalized.startsWith('test/') ||
        normalized.startsWith('test\\') ||
        normalized.startsWith('integration_test/') ||
        normalized.startsWith('integration_test\\') ||
        normalized.startsWith('test_driver/') ||
        normalized.startsWith('test_driver\\')) {
      return FileRole.test;
    }
    if (normalized.startsWith('tool/') ||
        normalized.startsWith('tool\\') ||
        normalized.startsWith('benchmark/') ||
        normalized.startsWith('benchmark\\') ||
        normalized.startsWith('web/') ||
        normalized.startsWith('web\\')) {
      return FileRole.auxiliary;
    }
    return FileRole.other;
  }

  /// Whether [relativeFilePath] is a Flutter main entrypoint (`lib/main.dart` or `lib/main_*.dart`).
  static bool isFlutterEntrypoint(String relativeFilePath) {
    final normalized = p.normalize(relativeFilePath).replaceAll(r'\', '/');
    final dir = p.dirname(normalized);
    final base = p.basename(normalized);
    return dir == 'lib' &&
        (base == 'main.dart' ||
            (base.startsWith('main_') && base.endsWith('.dart')));
  }
}

/// Harvester that discovers package topology, entrypoints, and roots.
class RootHarvester {
  final ZombieOptions options;

  const RootHarvester(this.options);

  /// Discovers the package topology from the filesystem.
  PackageTopology harvestTopology() {
    final rootDir = Directory(options.packagePath);
    if (!rootDir.existsSync()) {
      throw FileSystemException(
        'Target package directory does not exist',
        options.packagePath,
      );
    }

    final pubspecFile = File(p.join(options.packagePath, 'pubspec.yaml'));
    if (!pubspecFile.existsSync()) {
      throw FileSystemException(
        'Missing pubspec.yaml in package root',
        options.packagePath,
      );
    }

    if (!hasPackageConfig(options.packagePath) &&
        !hasEnclosingPackageConfig(options.packagePath)) {
      if (options.autoPubGet) {
        final result = runPubGet(options.packagePath, sdkPath: options.sdkPath);
        if (result.exitCode != 0) {
          final isFlutter = isFlutterPackage(options.packagePath);
          final toolName = isFlutter ? 'flutter' : 'dart';
          throw PackageResolutionException(
            'Failed to resolve dependencies with "$toolName pub get":\n'
            '${result.stderr}',
            options.packagePath,
          );
        }
      } else {
        throw PackageResolutionException(
          'Missing .dart_tool/package_config.json for '
          '"${options.packagePath}".\n'
          'Please run "dart pub get" (or "flutter pub get") before running '
          'zombie (or pass --pub-get).',
          options.packagePath,
        );
      }
    }

    final pubspecContent = pubspecFile.readAsStringSync();
    final packageName = _extractPackageName(pubspecContent);

    final publicLib = <String>[];
    final internalSrc = <String>[];
    final bin = <String>[];
    final example = <String>[];
    final auxiliary = <String>[];
    final test = <String>[];

    for (final entity in rootDir.listSync(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;

      final relPath = p.relative(entity.path, from: options.packagePath);
      if (_isExcluded(relPath)) continue;

      final normalized = p.normalize(relPath);
      if (normalized.startsWith('lib/src/') ||
          normalized.startsWith('lib/src\\')) {
        internalSrc.add(normalized);
      } else if (normalized.startsWith('lib/') ||
          normalized.startsWith('lib\\')) {
        publicLib.add(normalized);
      } else if (normalized.startsWith('bin/') ||
          normalized.startsWith('bin\\')) {
        bin.add(normalized);
      } else if (normalized.startsWith('example/') ||
          normalized.startsWith('example\\')) {
        if (options.exampleMode != ExampleMode.skip) {
          example.add(normalized);
        }
      } else if (normalized.startsWith('test/') ||
          normalized.startsWith('test\\') ||
          normalized.startsWith('integration_test/') ||
          normalized.startsWith('integration_test\\') ||
          normalized.startsWith('test_driver/') ||
          normalized.startsWith('test_driver\\')) {
        test.add(normalized);
      } else if (normalized.startsWith('tool/') ||
          normalized.startsWith('tool\\') ||
          normalized.startsWith('benchmark/') ||
          normalized.startsWith('benchmark\\') ||
          normalized.startsWith('web/') ||
          normalized.startsWith('web\\')) {
        auxiliary.add(normalized);
      }
    }

    // Harvest files from extra roots (companion test suites, external roots)
    for (final extraRoot in options.extraRoots) {
      if (extraRoot.trim().isEmpty) continue;
      final extraDir = Directory(
        p.normalize(
          p.isAbsolute(extraRoot)
              ? extraRoot
              : p.join(options.packagePath, extraRoot),
        ),
      );
      if (!extraDir.existsSync()) continue;
      for (final entity in extraDir.listSync(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final relPath = p.relative(entity.path, from: options.packagePath);
        if (_isExcluded(relPath)) continue;
        final normalized = p.normalize(relPath);
        test.add(normalized);
      }
    }

    final initialTopology = PackageTopology(
      packagePath: options.packagePath,
      packageName: packageName,
      publicLibFiles: publicLib,
      internalSrcFiles: internalSrc,
      executableFiles: bin,
      demonstrationFiles: example,
      auxiliaryFiles: auxiliary,
      testFiles: test,
    );

    final frameworkRoots = options.frameworkAdapter.harvestRoots(
      topology: initialTopology,
      packageDir: rootDir,
      pubspecContent: pubspecContent,
    );

    return PackageTopology(
      packagePath: options.packagePath,
      packageName: packageName,
      publicLibFiles: publicLib,
      internalSrcFiles: internalSrc,
      executableFiles: bin,
      demonstrationFiles: example,
      auxiliaryFiles: auxiliary,
      testFiles: test,
      frameworkRoots: frameworkRoots,
    );
  }

  bool _isExcluded(String relativePath) {
    final segments = p.split(p.normalize(relativePath));
    if (segments.isEmpty) return false;
    if (segments.contains('.dart_tool') ||
        segments.contains('.git') ||
        segments.first == 'build') {
      return true;
    }

    if (!options.includeGenerated) {
      final filename = p.basename(relativePath);
      if (filename.endsWith('.g.dart') ||
          filename.endsWith('.freezed.dart') ||
          filename.endsWith('.mocks.dart')) {
        return true;
      }
    }

    return false;
  }

  String _extractPackageName(String pubspecContent) {
    final match = RegExp(
      r'^name:\s*([a-zA-Z0-9_]+)',
      multiLine: true,
    ).firstMatch(pubspecContent);
    return match?.group(1) ?? 'unknown_package';
  }
}
