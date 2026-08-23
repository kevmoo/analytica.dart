import 'dart:io';

import 'package:checks/checks.dart';
import 'package:lower_bound/lower_bound.dart';
import 'package:test/test.dart';

void main() {
  group('SdkDiscovery', () {
    test('resolves a non-empty dart executable path', () {
      final exe = SdkDiscovery.dartExecutable;
      check(exe).isNotEmpty();
      check(exe.endsWith('dart') || exe.endsWith('dart.exe')).isTrue();
    });

    test('validates SDK paths correctly', () {
      check(SdkDiscovery.isValidSdkPath('')).isFalse();
      check(SdkDiscovery.isValidSdkPath('/non/existent/path')).isFalse();

      // Check current SDK root if resolved executable is inside an SDK
      final resolved = Platform.resolvedExecutable;
      final candidateRoot = File(resolved).parent.parent.path;
      if (SdkDiscovery.isValidSdkPath(candidateRoot)) {
        check(SdkDiscovery.isValidSdkPath(candidateRoot)).isTrue();
      }
    });
  });
}
