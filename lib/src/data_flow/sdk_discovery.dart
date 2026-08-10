import 'dart:io';
import 'package:path/path.dart' as p;

// Not exported from `lib/data_flow.dart`: this is an internal helper module,
// public within `src` so unit tests can exercise the discovery logic.
//
// TODO: Replace manual SDK discovery helpers with package:cli_util once
// https://github.com/dart-lang/tools/issues/2504 lands and is published.

/// Thrown when a usable Dart SDK cannot be located or a provided SDK path
/// is not a valid SDK root.
class SdkDiscoveryException implements Exception {
  final String message;

  const SdkDiscoveryException(this.message);

  @override
  String toString() => message;
}

/// Locates a Dart SDK root, probing in order: the running VM's executable,
/// the `DART_SDK` environment variable, `dart` binaries on `PATH` (including
/// Flutter checkouts, whose wrapper script hides the SDK under
/// `bin/cache/dart-sdk`), and finally `FLUTTER_ROOT`.
///
/// Returns `null` when no valid SDK is found — notably when running as a
/// standalone AOT executable (`dart run cognitive_complexity:data_flow@`),
/// where `Platform.resolvedExecutable` is the tool binary itself.
String? findSdkPath() =>
    _findSdkFromExecutable() ??
    _findSdkFromEnv() ??
    _findSdkFromPath() ??
    _findSdkFromFlutterRoot();

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

/// Resolves an SDK root from a directory containing a `dart` executable.
///
/// Handles the Flutter checkout layout, where `<flutter>/bin/dart` is a
/// wrapper script and the real SDK lives at `<flutter>/bin/cache/dart-sdk`.
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

/// Whether [path] looks like a Dart SDK root usable by the analyzer.
bool isValidSdk(String path) {
  final internal = Directory(p.join(path, 'lib', '_internal'));
  if (!internal.existsSync()) return false;
  return File(p.join(internal.path, 'libraries.dart')).existsSync() ||
      File(
        p.join(internal.path, 'sdk_library_metadata', 'lib', 'libraries.dart'),
      ).existsSync() ||
      File(
        p.join(path, 'bin', Platform.isWindows ? 'dart.exe' : 'dart'),
      ).existsSync();
}
