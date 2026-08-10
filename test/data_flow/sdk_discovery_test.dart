import 'dart:io';

import 'package:checks/checks.dart';
import 'package:cognitive_complexity/src/data_flow/sdk_discovery.dart';
import 'package:path/path.dart' as p;
import 'package:test/scaffolding.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

void main() {
  group('isValidSdk', () {
    test('accepts a root with lib/_internal/libraries.dart', () async {
      await d.dir('sdk', [
        d.dir('lib', [
          d.dir('_internal', [d.file('libraries.dart', '')]),
        ]),
      ]).create();

      check(isValidSdk('${d.sandbox}/sdk')).isTrue();
    });

    test('accepts a root with lib/_internal and bin/dart', () async {
      await d.dir('sdk', [
        d.dir('lib', [d.dir('_internal')]),
        d.dir('bin', [d.file('dart', '')]),
      ]).create();

      check(isValidSdk('${d.sandbox}/sdk')).isTrue();
    });

    test('rejects an AOT app bundle (bin only, no lib/_internal)', () async {
      await d.dir('bundle', [
        d.dir('bin', [d.file('data_flow', '')]),
      ]).create();

      check(isValidSdk('${d.sandbox}/bundle')).isFalse();
    });
  });

  group('resolveSdkFromDir', () {
    test('resolves a standard SDK layout from its bin directory', () async {
      await d.dir('sdk', [
        d.dir('lib', [
          d.dir('_internal', [d.file('libraries.dart', '')]),
        ]),
        d.dir('bin', [d.file('dart', '')]),
      ]).create();

      final sdkRoot = Directory('${d.sandbox}/sdk').resolveSymbolicLinksSync();
      check(resolveSdkFromDir(p.join(sdkRoot, 'bin'), 'dart')).equals(sdkRoot);
    });

    test('resolves a Flutter checkout via bin/cache/dart-sdk', () async {
      await d.dir('flutter', [
        d.dir('bin', [
          // Wrapper shell script, not a symlink into an SDK.
          d.file('dart', '#!/bin/sh\n'),
          d.dir('cache', [
            d.dir('dart-sdk', [
              d.dir('lib', [
                d.dir('_internal', [d.file('libraries.dart', '')]),
              ]),
              d.dir('bin', [d.file('dart', '')]),
            ]),
          ]),
        ]),
      ]).create();

      final binDir = '${d.sandbox}/flutter/bin';
      check(
        resolveSdkFromDir(binDir, 'dart'),
      ).equals(p.join(binDir, 'cache', 'dart-sdk'));
    });

    test(
      'resolves a Windows-style Flutter checkout when probing dart.exe',
      () async {
        await d.dir('flutter_win', [
          d.dir('bin', [
            // Windows Flutter checkouts ship dart.bat, never bin/dart.exe.
            d.file('dart.bat', '@echo off\r\n'),
            d.dir('cache', [
              d.dir('dart-sdk', [
                d.dir('lib', [
                  d.dir('_internal', [d.file('libraries.dart', '')]),
                ]),
                d.dir('bin', [d.file('dart.exe', '')]),
              ]),
            ]),
          ]),
        ]).create();

        final binDir = '${d.sandbox}/flutter_win/bin';
        check(
          resolveSdkFromDir(binDir, 'dart.exe'),
        ).equals(p.join(binDir, 'cache', 'dart-sdk'));
      },
    );

    test('returns null when the directory has no dart executable', () async {
      await d.dir('empty').create();

      check(resolveSdkFromDir('${d.sandbox}/empty', 'dart')).isNull();
    });

    test('returns null for a dart binary outside any SDK', () async {
      await d.dir('stray', [d.file('dart', '')]).create();

      check(resolveSdkFromDir('${d.sandbox}/stray', 'dart')).isNull();
    });
  });
}
