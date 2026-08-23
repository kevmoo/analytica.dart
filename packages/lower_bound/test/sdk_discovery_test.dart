import 'dart:io';

import 'package:checks/checks.dart';
import 'package:lower_bound/lower_bound.dart';
import 'package:test/test.dart';

void main() {
  group('SdkDiscovery', () {
    test('resolves a non-empty dart executable path', () {
      final exe = dartExecutable;
      check(exe).isNotEmpty();
      check(exe.endsWith('dart') || exe.endsWith('dart.exe')).isTrue();
    });

    test('validates SDK paths correctly', () {
      check(isValidSdkPath('')).isFalse();
      check(isValidSdkPath('/non/existent/path')).isFalse();

      // Check current SDK root if resolved executable is inside an SDK
      final resolved = Platform.resolvedExecutable;
      final candidateRoot = File(resolved).parent.parent.path;
      if (isValidSdkPath(candidateRoot)) {
        check(isValidSdkPath(candidateRoot)).isTrue();
      }
    });
  });
}
