import 'dart:io';

import 'package:path/path.dart' as p;

String? _memoizedDartExecutable;

/// Returns the resolved absolute path to the `dart` (or `dart.exe`)
/// executable.
String get dartExecutable {
  return _memoizedDartExecutable ??= _resolveDartExecutable();
}

/// Checks if [candidatePath] represents a valid Dart SDK root directory.
bool isValidSdkPath(String candidatePath) {
  if (candidatePath.isEmpty) return false;
  final dir = Directory(candidatePath);
  if (!dir.existsSync()) return false;

  final internalDir = Directory(p.join(candidatePath, 'lib', '_internal'));
  final versionFile = File(p.join(candidatePath, 'version'));
  final binDart = File(
    p.join(candidatePath, 'bin', Platform.isWindows ? 'dart.exe' : 'dart'),
  );

  return (internalDir.existsSync() || versionFile.existsSync()) &&
      binDart.existsSync();
}

String _resolveDartExecutable() {
  return _fromDartSdkEnv() ??
      _fromResolvedExecutable() ??
      _fromPathEnv() ??
      _fromFlutterRoot() ??
      (Platform.isWindows ? 'dart.exe' : 'dart');
}

String? _fromDartSdkEnv() {
  final envSdk = Platform.environment['DART_SDK'];
  if (envSdk != null && envSdk.isNotEmpty && isValidSdkPath(envSdk)) {
    return p.join(envSdk, 'bin', Platform.isWindows ? 'dart.exe' : 'dart');
  }
  return null;
}

String? _fromResolvedExecutable() {
  final resolvedExe = Platform.resolvedExecutable;
  if (resolvedExe.isEmpty) return null;
  final candidateSdk = p.dirname(p.dirname(resolvedExe));
  return isValidSdkPath(candidateSdk) ? resolvedExe : null;
}

String? _fromPathEnv() {
  final pathEnv = Platform.environment['PATH'] ?? '';
  final separator = Platform.isWindows ? ';' : ':';
  final searchNames = Platform.isWindows
      ? const ['dart.exe', 'dart.bat', 'dart']
      : const ['dart'];

  for (final segment in pathEnv.split(separator)) {
    final trimmed = segment.trim();
    if (trimmed.isEmpty) continue;
    final resolved = _probePathSegment(trimmed, searchNames);
    if (resolved != null) return resolved;
  }
  return null;
}

String? _probePathSegment(String segment, List<String> searchNames) {
  for (final name in searchNames) {
    final candidate = File(p.join(segment, name));
    final resolved = _probeSdkFromCandidate(candidate);
    if (resolved != null) return resolved;
  }
  return null;
}

String? _probeSdkFromCandidate(File candidate) {
  if (!candidate.existsSync()) return null;
  try {
    final realPath = candidate.resolveSymbolicLinksSync();
    final candidateSdk = p.dirname(p.dirname(realPath));
    if (isValidSdkPath(candidateSdk)) {
      return p.join(
        candidateSdk,
        'bin',
        Platform.isWindows ? 'dart.exe' : 'dart',
      );
    }

    final flutterCacheSdk = p.join(p.dirname(realPath), 'cache', 'dart-sdk');
    if (isValidSdkPath(flutterCacheSdk)) {
      return p.join(
        flutterCacheSdk,
        'bin',
        Platform.isWindows ? 'dart.exe' : 'dart',
      );
    }
  } catch (_) {
    // Permission or link resolution error
  }
  return null;
}

String? _fromFlutterRoot() {
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot == null || flutterRoot.isEmpty) return null;
  final flutterSdk = p.join(flutterRoot, 'bin', 'cache', 'dart-sdk');
  if (isValidSdkPath(flutterSdk)) {
    return p.join(flutterSdk, 'bin', Platform.isWindows ? 'dart.exe' : 'dart');
  }
  return null;
}
