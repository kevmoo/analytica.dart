import 'dart:io';

import 'package:analytica/sdk_discovery.dart';
import 'package:path/path.dart' as p;

import 'models.dart';
import 'workspace_discovery.dart';

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

  /// Whether declarations in this file are candidates for undead detection.
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
  final List<String> extraProductionFiles;
  final List<String> extraTestFiles;

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
    this.extraProductionFiles = const [],
    this.extraTestFiles = const [],
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
    ...extraProductionFiles,
    ...extraTestFiles,
  ];

  /// Resolves the role of a given [relativeFilePath].
  FileRole roleOf(String relativeFilePath) {
    final normalized = p.normalize(relativeFilePath);
    if (testFiles.contains(normalized) || extraTestFiles.contains(normalized)) {
      return FileRole.test;
    }
    if (extraProductionFiles.contains(normalized)) {
      return FileRole.other;
    }
    return _classifyPathPrefix(normalized.replaceAll(r'\', '/'));
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
  final UndeadOptions options;

  const RootHarvester(this.options);

  /// Discovers the package topology from the filesystem.
  PackageTopology harvestTopology() {
    final rootDir = Directory(options.packagePath);
    final pubspecFile = File(p.join(options.packagePath, 'pubspec.yaml'));
    _verifyPackageAndConfig(rootDir, pubspecFile);

    final pubspecContent = pubspecFile.readAsStringSync();
    final packageName = _extractPackageName(pubspecContent);

    final files = _classifyPackageFiles(rootDir);
    final extraProduction = <String>[];
    final extraTest = <String>[];

    _discoverWorkspaceConsumers(packageName, extraProduction, extraTest);
    _harvestExtraRoots(extraProduction, extraTest);

    final initialTopology = PackageTopology(
      packagePath: options.packagePath,
      packageName: packageName,
      publicLibFiles: files.publicLib,
      internalSrcFiles: files.internalSrc,
      executableFiles: files.bin,
      demonstrationFiles: files.example,
      auxiliaryFiles: files.auxiliary,
      testFiles: files.test,
      extraProductionFiles: extraProduction,
      extraTestFiles: extraTest,
    );

    final frameworkRoots = options.frameworkAdapter.harvestRoots(
      topology: initialTopology,
      packageDir: rootDir,
      pubspecContent: pubspecContent,
    );

    return PackageTopology(
      packagePath: options.packagePath,
      packageName: packageName,
      publicLibFiles: files.publicLib,
      internalSrcFiles: files.internalSrc,
      executableFiles: files.bin,
      demonstrationFiles: files.example,
      auxiliaryFiles: files.auxiliary,
      testFiles: files.test,
      frameworkRoots: frameworkRoots,
      extraProductionFiles: extraProduction,
      extraTestFiles: extraTest,
    );
  }

  void _verifyPackageAndConfig(Directory rootDir, File pubspecFile) {
    if (!rootDir.existsSync()) {
      throw FileSystemException(
        'Target package directory does not exist',
        options.packagePath,
      );
    }

    if (!pubspecFile.existsSync()) {
      throw FileSystemException(
        'Missing pubspec.yaml in package root',
        options.packagePath,
      );
    }

    if (hasPackageConfig(options.packagePath) ||
        hasEnclosingPackageConfig(options.packagePath)) {
      return;
    }

    if (!options.autoPubGet) {
      throw PackageResolutionException(
        'Missing .dart_tool/package_config.json for '
        '"${options.packagePath}".\n'
        'Please run "dart pub get" (or "flutter pub get") before running '
        'undead (or pass --pub-get).',
        options.packagePath,
      );
    }

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
  }

  _PackageFiles _classifyPackageFiles(Directory rootDir) {
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
      final role = _classifyPathPrefix(normalized.replaceAll(r'\', '/'));
      switch (role) {
        case FileRole.internalSrc:
          internalSrc.add(normalized);
        case FileRole.publicLib:
          publicLib.add(normalized);
        case FileRole.executable:
          bin.add(normalized);
        case FileRole.demonstration:
          if (options.exampleMode != ExampleMode.skip) {
            example.add(normalized);
          }
        case FileRole.test:
          test.add(normalized);
        case FileRole.auxiliary:
          auxiliary.add(normalized);
        case FileRole.other:
          break;
      }
    }

    return (
      publicLib: publicLib,
      internalSrc: internalSrc,
      bin: bin,
      example: example,
      auxiliary: auxiliary,
      test: test,
    );
  }

  void _discoverWorkspaceConsumers(
    String packageName,
    List<String> extraProduction,
    List<String> extraTest,
  ) {
    if (!options.workspaceDiscovery) return;

    const discovery = WorkspaceConsumerDiscovery();
    final discovered = discovery.discoverConsumers(
      packagePath: options.packagePath,
      targetPackageName: packageName,
    );
    for (final root in discovered.productionRoots) {
      final relPath = p.relative(root, from: options.packagePath);
      if (!_isExcludedFromExtraRoot(relPath)) {
        extraProduction.add(p.normalize(relPath));
      }
    }
    for (final root in discovered.testRoots) {
      final relPath = p.relative(root, from: options.packagePath);
      if (!_isExcludedFromExtraRoot(relPath)) {
        extraTest.add(p.normalize(relPath));
      }
    }
  }

  void _harvestExtraRoots(
    List<String> extraProduction,
    List<String> extraTest,
  ) {
    for (final extraRoot in options.extraRoots) {
      if (extraRoot.trim().isEmpty) continue;
      final extraPath = p.normalize(
        p.isAbsolute(extraRoot)
            ? extraRoot
            : p.join(options.packagePath, extraRoot),
      );

      final extraFile = File(extraPath);
      if (extraFile.existsSync() && extraPath.endsWith('.dart')) {
        final relPath = p.relative(extraPath, from: options.packagePath);
        if (!_isExcludedFromExtraRoot(relPath)) {
          extraProduction.add(p.normalize(relPath));
        }
        continue;
      }

      _harvestExtraDirectory(extraPath, extraProduction, extraTest);
    }
  }

  void _harvestExtraDirectory(
    String extraPath,
    List<String> extraProduction,
    List<String> extraTest,
  ) {
    final extraDir = Directory(extraPath);
    if (!extraDir.existsSync()) return;

    final libSubdir = Directory(p.join(extraPath, 'lib'));
    final testSubdir = Directory(p.join(extraPath, 'test'));

    if (libSubdir.existsSync() || testSubdir.existsSync()) {
      _scanDartFiles(libSubdir, extraProduction.add);
      _scanDartFiles(testSubdir, extraTest.add);
    } else {
      _scanDartFiles(extraDir, extraTest.add);
    }
  }

  void _scanDartFiles(Directory dir, void Function(String relPath) onFile) {
    if (!dir.existsSync()) return;
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final relPath = p.relative(entity.path, from: options.packagePath);
      if (_isExcludedFromExtraRoot(relPath)) continue;
      onFile(p.normalize(relPath));
    }
  }

  bool _isExcluded(String relativePath) =>
      options.pathFilter.isExcluded(relativePath);

  bool _isExcludedFromExtraRoot(String relativePath) =>
      options.pathFilter.isExcluded(relativePath);

  String _extractPackageName(String pubspecContent) {
    final match = RegExp(
      r'^name:\s*([a-zA-Z0-9_]+)',
      multiLine: true,
    ).firstMatch(pubspecContent);
    return match?.group(1) ?? 'unknown_package';
  }
}

typedef _PackageFiles = ({
  List<String> publicLib,
  List<String> internalSrc,
  List<String> bin,
  List<String> example,
  List<String> auxiliary,
  List<String> test,
});

FileRole _classifyPathPrefix(String path) {
  if (path.startsWith('lib/src/')) return FileRole.internalSrc;
  if (path.startsWith('lib/')) return FileRole.publicLib;
  if (path.startsWith('bin/')) return FileRole.executable;
  if (path.startsWith('example/')) return FileRole.demonstration;
  if (path.startsWith('test/') ||
      path.startsWith('integration_test/') ||
      path.startsWith('test_driver/')) {
    return FileRole.test;
  }
  if (path.startsWith('tool/') ||
      path.startsWith('benchmark/') ||
      path.startsWith('web/')) {
    return FileRole.auxiliary;
  }
  return FileRole.other;
}
