import 'dart:io';

import 'package:path/path.dart' as p;

/// Discovers the active Dart SDK and resolves the `dart` binary executable
/// path.
///
/// Resilient across JIT execution (`dart run`), compiled AOT binaries
/// (`dart compile exe` / `dart install`), and Flutter SDK wrapper environments.
class SdkDiscovery {
  static String? _memoizedDartExecutable;

  /// Returns the resolved absolute path to the `dart` (or `dart.exe`)
  /// executable.
  static String get dartExecutable {
    return _memoizedDartExecutable ??= _resolveDartExecutable();
  }

  /// Checks if [candidatePath] represents a valid Dart SDK root directory.
  static bool isValidSdkPath(String candidatePath) {
    if (candidatePath.isEmpty) return false;
    final dir = Directory(candidatePath);
    if (!dir.existsSync()) return false;

    // A valid Dart SDK root contains either lib/_internal or bin/dart/version
    final internalDir = Directory(p.join(candidatePath, 'lib', '_internal'));
    final versionFile = File(p.join(candidatePath, 'version'));
    final binDart = File(
      p.join(candidatePath, 'bin', Platform.isWindows ? 'dart.exe' : 'dart'),
    );

    return (internalDir.existsSync() || versionFile.existsSync()) &&
        binDart.existsSync();
  }

  static String _resolveDartExecutable() {
    // 1. Check DART_SDK environment variable
    final envSdk = Platform.environment['DART_SDK'];
    if (envSdk != null && envSdk.isNotEmpty && isValidSdkPath(envSdk)) {
      return p.join(envSdk, 'bin', Platform.isWindows ? 'dart.exe' : 'dart');
    }

    // 2. Check Platform.resolvedExecutable (Fast path for JIT VM)
    final resolvedExe = Platform.resolvedExecutable;
    if (resolvedExe.isNotEmpty) {
      final candidateSdk = p.dirname(p.dirname(resolvedExe));
      if (isValidSdkPath(candidateSdk)) {
        return resolvedExe;
      }
    }

    // 3. Scan system PATH
    final pathEnv = Platform.environment['PATH'] ?? '';
    final separator = Platform.isWindows ? ';' : ':';
    final searchNames = Platform.isWindows
        ? ['dart.exe', 'dart.bat', 'dart']
        : ['dart'];

    for (final segment in pathEnv.split(separator)) {
      final trimmed = segment.trim();
      if (trimmed.isEmpty) continue;

      for (final name in searchNames) {
        final candidate = File(p.join(trimmed, name));
        if (candidate.existsSync()) {
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

            // Check for Flutter cache layout (e.g. flutter/bin/cache/dart-sdk)
            final flutterCacheSdk = p.join(
              p.dirname(realPath),
              'cache',
              'dart-sdk',
            );
            if (isValidSdkPath(flutterCacheSdk)) {
              return p.join(
                flutterCacheSdk,
                'bin',
                Platform.isWindows ? 'dart.exe' : 'dart',
              );
            }
          } catch (_) {
            // Permission or link resolution error; continue scanning
          }
        }
      }
    }

    // 4. Check FLUTTER_ROOT environment variable
    final flutterRoot = Platform.environment['FLUTTER_ROOT'];
    if (flutterRoot != null && flutterRoot.isNotEmpty) {
      final flutterSdk = p.join(flutterRoot, 'bin', 'cache', 'dart-sdk');
      if (isValidSdkPath(flutterSdk)) {
        return p.join(
          flutterSdk,
          'bin',
          Platform.isWindows ? 'dart.exe' : 'dart',
        );
      }
    }

    // Fallback to literal 'dart' or 'dart.exe'
    return Platform.isWindows ? 'dart.exe' : 'dart';
  }
}
