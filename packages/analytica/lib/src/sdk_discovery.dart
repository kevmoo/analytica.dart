import 'dart:io';
import 'package:path/path.dart' as p;
import 'exceptions.dart';

/// Throwing getter that locates a Dart SDK root using [findSdkPath].
///
/// Throws [SdkDiscoveryException] if no valid Dart SDK can be located.
String get sdkPath {
  final path = findSdkPath();
  if (path == null) {
    throw const SdkDiscoveryException(
      'Cannot locate a Dart SDK. Pass --sdk-path, set the DART_SDK environment '
      'variable, or ensure a Dart SDK is on PATH.',
    );
  }
  return path;
}

/// Locates a Dart SDK root, probing in order: the running VM's executable,
/// the `DART_SDK` environment variable, `dart` binaries on `PATH` (including
/// Flutter checkouts, whose wrapper script hides the SDK under
/// `bin/cache/dart-sdk`), `FLUTTER_ROOT`, and standard system SDK locations.
///
/// Returns `null` when no valid SDK is found — notably when running as a
/// standalone AOT executable (`dart compile exe`), where
/// `Platform.resolvedExecutable` is the tool binary itself.
String? findSdkPath() =>
    _findSdkFromExecutable() ??
    _findSdkFromEnv() ??
    _findSdkFromPath() ??
    _findSdkFromFlutterRoot() ??
    _findSdkFromStandardLocations();

/// Throwing getter that returns the absolute path to the `dart` binary.
///
/// Uses `.exe` on Windows to avoid spawning batch wrapper scripts.
/// Throws [SdkDiscoveryException] if the executable cannot be located.
String get dartExecutable {
  final exe = findDartExecutable();
  if (exe == null) {
    throw const SdkDiscoveryException(
      'Cannot locate dart executable. Ensure a Dart SDK is on PATH or set '
      'DART_SDK.',
    );
  }
  return exe;
}

/// Returns the absolute path to the `dart` executable inside the discovered
/// SDK, or `null` if no valid SDK/binary is found.
///
/// Accepts an optional [sdkPath] override.
String? findDartExecutable({String? sdkPath}) {
  final sdk = sdkPath ?? findSdkPath();
  if (sdk == null) return null;
  final exeName = Platform.isWindows ? 'dart.exe' : 'dart';
  final exe = p.join(sdk, 'bin', exeName);
  return File(exe).existsSync() ? exe : null;
}

String? _findSdkFromExecutable() {
  final exe = File(Platform.resolvedExecutable);
  if (!exe.existsSync()) return null;

  try {
    final resolved = exe.resolveSymbolicLinksSync();
    final candidate = p.dirname(p.dirname(resolved));
    return isValidSdk(candidate) ? candidate : null;
  } catch (_) {
    return null;
  }
}

String? _findSdkFromEnv() {
  final envSdk = Platform.environment['DART_SDK'];
  if (envSdk != null && isValidSdk(envSdk)) {
    return envSdk;
  }
  return null;
}

String? _findSdkFromPath() {
  final pathEnv = Platform.environment['PATH'];
  if (pathEnv == null || pathEnv.isEmpty) return null;

  final separator = Platform.isWindows ? ';' : ':';
  final executableName = Platform.isWindows ? 'dart.exe' : 'dart';

  for (final dir in pathEnv.split(separator)) {
    if (dir.trim().isEmpty) continue;
    final candidate = resolveSdkFromDir(dir, executableName);
    if (candidate != null) return candidate;
  }

  return null;
}

String? _findSdkFromFlutterRoot() {
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot == null || flutterRoot.isEmpty) return null;
  final candidate = p.join(flutterRoot, 'bin', 'cache', 'dart-sdk');
  return isValidSdk(candidate) ? candidate : null;
}

String? _findSdkFromStandardLocations() {
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  final candidates = <String>[
    if (home != null) ...[
      p.join(home, 'github', 'flutter', 'bin', 'cache', 'dart-sdk'),
      p.join(home, 'flutter', 'bin', 'cache', 'dart-sdk'),
      p.join(home, '.flutter', 'bin', 'cache', 'dart-sdk'),
    ],
    if (!Platform.isWindows) ...[
      '/usr/lib/google-dartlang',
      '/usr/lib/dart',
      '/usr/local/opt/dart/libexec',
      '/opt/homebrew/opt/dart/libexec',
    ],
  ];

  for (final candidate in candidates) {
    if (isValidSdk(candidate)) return candidate;
  }
  return null;
}

/// Resolves an SDK root from a directory containing a `dart` executable.
///
/// Handles the Flutter checkout layout, where `<flutter>/bin/dart` is a
/// wrapper script and the real SDK lives at `<flutter>/bin/cache/dart-sdk`,
/// as well as custom smart dispatch wrapper scripts.
String? resolveSdkFromDir(String dir, String executableName) {
  final dartBinary = File(p.join(dir, executableName));
  if (dartBinary.existsSync()) {
    try {
      final resolved = dartBinary.resolveSymbolicLinksSync();
      final candidate = p.dirname(p.dirname(resolved));
      if (isValidSdk(candidate)) return candidate;
    } catch (_) {
      // Fall through to the Flutter wrapper probe.
    }

    final scriptSdk = _extractSdkFromScript(dartBinary);
    if (scriptSdk != null && isValidSdk(scriptSdk)) return scriptSdk;
  }

  // Flutter checkouts ship wrapper scripts in `bin/` (`dart`, plus `dart.bat`
  // on Windows — never `dart.exe`, which lives inside the cached SDK), so the
  // exact executable probed above may be absent. Probe `cache/dart-sdk`
  // whenever any Dart wrapper is present in the directory.
  final hasDartWrapper =
      dartBinary.existsSync() ||
      File(p.join(dir, 'dart')).existsSync() ||
      File(p.join(dir, 'dart.bat')).existsSync();
  if (!hasDartWrapper) return null;

  final flutterCache = p.join(dir, 'cache', 'dart-sdk');
  return isValidSdk(flutterCache) ? flutterCache : null;
}

/// Inspects a potential shell/batch wrapper script for embedded SDK paths.
String? _extractSdkFromScript(File file) {
  try {
    final stat = file.statSync();
    if (stat.type != FileSystemEntityType.file || stat.size > 64 * 1024) {
      return null;
    }

    final contents = file.readAsStringSync();
    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';

    // Look for quoted or raw path references in the wrapper script
    final pathRegex = RegExp(
      r'''(?:["']?)([/~\$][^"'\s\n\r]+\b(?:dart-sdk|dart))(?:\b|["'])''',
    );
    for (final match in pathRegex.allMatches(contents)) {
      var candidate = match.group(1);
      if (candidate == null) continue;
      if (home.isNotEmpty) {
        candidate = candidate
            .replaceAll(r'${HOME}', home)
            .replaceAll(r'$HOME', home)
            .replaceAll('~', home);
      }

      // If the path points to bin/dart, check its parent SDK
      if (candidate.endsWith('dart')) {
        final sdkCandidate = p.dirname(p.dirname(candidate));
        if (isValidSdk(sdkCandidate)) return sdkCandidate;
      }
      if (isValidSdk(candidate)) return candidate;
    }
  } catch (_) {
    // Non-fatal if script reading fails.
  }
  return null;
}

/// Alias for [isValidSdk].
bool isValidSdkPath(String path) => isValidSdk(path);

/// Whether [path] looks like a Dart SDK root usable by the analyzer.
bool isValidSdk(String path) {
  final internal = Directory(p.join(path, 'lib', '_internal'));
  final hasInternal = internal.existsSync();
  final hasLibrariesJson = File(
    p.join(path, 'lib', 'libraries.json'),
  ).existsSync();

  if (!hasInternal && !hasLibrariesJson) return false;

  return hasLibrariesJson ||
      File(p.join(internal.path, 'libraries.dart')).existsSync() ||
      File(p.join(internal.path, 'allowed_experiments.json')).existsSync() ||
      File(
        p.join(internal.path, 'sdk_library_metadata', 'lib', 'libraries.dart'),
      ).existsSync() ||
      File(
        p.join(path, 'bin', Platform.isWindows ? 'dart.exe' : 'dart'),
      ).existsSync();
}

/// Throwing getter that returns the absolute or command path to `flutter`.
///
/// Throws [SdkDiscoveryException] if no Flutter executable can be located.
String get flutterExecutable {
  final exe = findFlutterExecutable();
  if (exe == null) {
    throw const SdkDiscoveryException(
      'Cannot locate flutter executable. Set FLUTTER_ROOT or ensure flutter is '
      'on PATH.',
    );
  }
  return exe;
}

/// Locates the `flutter` CLI executable, probing `FLUTTER_ROOT`, `PATH`, and
/// standard Flutter checkout directories.
String? findFlutterExecutable({String? flutterRoot}) {
  final root = flutterRoot ?? Platform.environment['FLUTTER_ROOT'];
  final exeName = Platform.isWindows ? 'flutter.bat' : 'flutter';

  if (root != null && root.isNotEmpty) {
    final candidate = p.join(root, 'bin', exeName);
    if (File(candidate).existsSync()) return candidate;
  }

  final pathEnv = Platform.environment['PATH'];
  if (pathEnv != null && pathEnv.isNotEmpty) {
    final separator = Platform.isWindows ? ';' : ':';
    for (final dir in pathEnv.split(separator)) {
      if (dir.trim().isEmpty) continue;
      final candidate = p.join(dir, exeName);
      if (File(candidate).existsSync()) return candidate;
    }
  }

  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (home != null) {
    final candidates = [
      p.join(home, 'github', 'flutter', 'bin', exeName),
      p.join(home, 'flutter', 'bin', exeName),
      p.join(home, '.flutter', 'bin', exeName),
    ];
    for (final candidate in candidates) {
      if (File(candidate).existsSync()) return candidate;
    }
  }

  return null;
}

/// Whether the package at [packagePath] is a Flutter package (e.g. declares
/// `sdk: flutter` or depends on `package:flutter`).
bool isFlutterPackage(String packagePath) {
  final pubspec = File(p.join(packagePath, 'pubspec.yaml'));
  if (!pubspec.existsSync()) return false;
  try {
    return isFlutterPubspec(pubspec.readAsStringSync());
  } catch (_) {
    return false;
  }
}

/// Whether [pubspecContent] indicates a Flutter package.
bool isFlutterPubspec(String pubspecContent) {
  return pubspecContent.contains('sdk: flutter') ||
      pubspecContent.contains('package:flutter') ||
      RegExp(r'^\s*flutter:\s*$', multiLine: true).hasMatch(pubspecContent);
}

/// Whether [packagePath] contains a `.dart_tool/package_config.json` file.
bool hasPackageConfig(String packagePath) {
  return File(
    p.join(packagePath, '.dart_tool', 'package_config.json'),
  ).existsSync();
}

/// Whether [packagePath] or any ancestor directory contains a
/// `.dart_tool/package_config.json` file.
bool hasEnclosingPackageConfig(String packagePath) {
  try {
    var dir = Directory(p.normalize(p.absolute(packagePath))).parent;
    while (dir.path != dir.parent.path) {
      final config = File(
        p.join(dir.path, '.dart_tool', 'package_config.json'),
      );
      if (config.existsSync()) {
        return true;
      }
      dir = dir.parent;
    }
  } catch (_) {}
  return false;
}

/// Runs `pub get` (routing to `flutter pub get` or `dart pub get`) for the
/// package at [packagePath].
ProcessResult runPubGet(
  String packagePath, {
  String? sdkPath,
  String? flutterRoot,
  List<String> additionalArgs = const [],
}) {
  final isFlutter = isFlutterPackage(packagePath);
  final String executable;
  final List<String> args;

  if (isFlutter) {
    final flutterExe = findFlutterExecutable(flutterRoot: flutterRoot);
    if (flutterExe == null) {
      throw const SdkDiscoveryException(
        'Cannot locate flutter executable to resolve dependencies. Set '
        'FLUTTER_ROOT or ensure flutter is on PATH.',
      );
    }
    executable = flutterExe;
    args = ['pub', 'get', ...additionalArgs];
  } else {
    executable = findDartExecutable(sdkPath: sdkPath) ?? 'dart';
    args = ['pub', 'get', ...additionalArgs];
  }

  return Process.runSync(executable, args, workingDirectory: packagePath);
}
