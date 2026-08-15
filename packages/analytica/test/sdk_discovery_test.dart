import 'dart:io';

import 'package:analytica/analytica.dart';
import 'package:checks/checks.dart';
import 'package:path/path.dart' as p;
import 'package:test/scaffolding.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

void main() {
  group('isValidSdk / isValidSdkPath', () {
    test('accepts a root with lib/_internal/libraries.dart', () async {
      await d.dir('sdk', [
        d.dir('lib', [
          d.dir('_internal', [d.file('libraries.dart', '')]),
        ]),
      ]).create();

      check(isValidSdk('${d.sandbox}/sdk')).isTrue();
      check(isValidSdkPath('${d.sandbox}/sdk')).isTrue();
    });

    test('accepts a root with lib/libraries.json', () async {
      await d.dir('sdk_json', [
        d.dir('lib', [d.file('libraries.json', '{}')]),
      ]).create();

      check(isValidSdk('${d.sandbox}/sdk_json')).isTrue();
      check(isValidSdkPath('${d.sandbox}/sdk_json')).isTrue();
    });

    test(
      'accepts a root with lib/_internal/allowed_experiments.json',
      () async {
        await d.dir('sdk_exp', [
          d.dir('lib', [
            d.dir('_internal', [d.file('allowed_experiments.json', '{}')]),
          ]),
        ]).create();

        check(isValidSdk('${d.sandbox}/sdk_exp')).isTrue();
        check(isValidSdkPath('${d.sandbox}/sdk_exp')).isTrue();
      },
    );

    test('accepts a root with lib/_internal and bin/dart', () async {
      await d.dir('sdk', [
        d.dir('lib', [d.dir('_internal')]),
        d.dir('bin', [d.file('dart', '')]),
      ]).create();

      check(isValidSdk('${d.sandbox}/sdk')).isTrue();
      check(isValidSdkPath('${d.sandbox}/sdk')).isTrue();
    });

    test('rejects an AOT app bundle (bin only, no lib/_internal)', () async {
      await d.dir('bundle', [
        d.dir('bin', [d.file('tool_exe', '')]),
      ]).create();

      check(isValidSdk('${d.sandbox}/bundle')).isFalse();
      check(isValidSdkPath('${d.sandbox}/bundle')).isFalse();
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

    test(
      'resolves SDK from a custom shell wrapper script containing SDK path',
      () async {
        await d.dir('real_sdk', [
          d.dir('lib', [
            d.dir('_internal', [d.file('libraries.dart', '')]),
          ]),
          d.dir('bin', [d.file('dart', '')]),
        ]).create();

        final realSdkRoot = Directory(
          '${d.sandbox}/real_sdk',
        ).resolveSymbolicLinksSync();

        await d.dir('custom_bin', [
          d.file(
            'dart',
            '#!/usr/bin/env bash\n'
                'exec "$realSdkRoot/bin/dart" "\$@"\n',
          ),
        ]).create();

        final customBin = '${d.sandbox}/custom_bin';
        check(resolveSdkFromDir(customBin, 'dart')).equals(realSdkRoot);
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

  group('findSdkPath & sdkPath', () {
    test('finds SDK in running environment', () {
      final path = findSdkPath();
      check(path).isNotNull();
      check(isValidSdk(path!)).isTrue();
      check(sdkPath).equals(path);
    });

    test('finds Dart executable', () {
      final exe = findDartExecutable();
      check(exe).isNotNull();
      check(File(exe!).existsSync()).isTrue();
      check(dartExecutable).equals(exe);
    });

    test('finds Dart executable with custom sdkPath override', () async {
      final exeName = Platform.isWindows ? 'dart.exe' : 'dart';
      await d.dir('custom_sdk', [
        d.dir('lib', [
          d.dir('_internal', [d.file('libraries.dart', '')]),
        ]),
        d.dir('bin', [d.file(exeName, '')]),
      ]).create();

      final customSdk = '${d.sandbox}/custom_sdk';
      final exe = findDartExecutable(sdkPath: customSdk);
      check(exe).equals(p.join(customSdk, 'bin', exeName));
    });

    test(
      'findDartExecutable returns null when sdkPath has no binary',
      () async {
        await d.dir('invalid_sdk', [
          d.dir('lib', [d.dir('_internal')]),
        ]).create();

        final invalidSdk = '${d.sandbox}/invalid_sdk';
        final exe = findDartExecutable(sdkPath: invalidSdk);
        check(exe).isNull();
      },
    );
  });

  group('findFlutterExecutable & flutterExecutable', () {
    test('finds flutter executable from flutterRoot override', () async {
      final exeName = Platform.isWindows ? 'flutter.bat' : 'flutter';
      await d.dir('custom_flutter', [
        d.dir('bin', [d.file(exeName, '')]),
      ]).create();

      final root = '${d.sandbox}/custom_flutter';
      final exe = findFlutterExecutable(flutterRoot: root);
      check(exe).equals(p.join(root, 'bin', exeName));
    });

    test(
      'returns default command name when no flutterRoot override exists',
      () {
        final exe = findFlutterExecutable();
        check(exe).isNotNull();
      },
    );
  });

  group('Flutter package & pubspec detection', () {
    test('detects Flutter package from sdk: flutter in pubspec', () async {
      await d.dir('flutter_pkg', [
        d.file('pubspec.yaml', '''
name: flutter_pkg
environment:
  sdk: '^3.5.0'
  flutter: '>=3.0.0'
dependencies:
  flutter:
    sdk: flutter
'''),
      ]).create();

      check(isFlutterPackage('${d.sandbox}/flutter_pkg')).isTrue();
    });

    test('detects pure Dart package as non-Flutter', () async {
      await d.dir('dart_pkg', [
        d.file('pubspec.yaml', '''
name: dart_pkg
environment:
  sdk: '^3.5.0'
'''),
      ]).create();

      check(isFlutterPackage('${d.sandbox}/dart_pkg')).isFalse();
    });

    test('returns false for non-existent directory', () {
      check(isFlutterPackage('${d.sandbox}/non_existent_pkg')).isFalse();
    });
  });

  group('hasPackageConfig & hasEnclosingPackageConfig', () {
    test('detects direct .dart_tool/package_config.json', () async {
      await d.dir('direct_pkg', [
        d.dir('.dart_tool', [d.file('package_config.json', '{}')]),
      ]).create();

      check(hasPackageConfig('${d.sandbox}/direct_pkg')).isTrue();
      check(hasEnclosingPackageConfig('${d.sandbox}/direct_pkg')).isFalse();
    });

    test('detects enclosing ancestor package config', () async {
      await d.dir('workspace', [
        d.dir('.dart_tool', [d.file('package_config.json', '{}')]),
        d.dir('sub_pkg', [d.file('pubspec.yaml', 'name: sub_pkg')]),
      ]).create();

      check(hasPackageConfig('${d.sandbox}/workspace/sub_pkg')).isFalse();
      check(
        hasEnclosingPackageConfig('${d.sandbox}/workspace/sub_pkg'),
      ).isTrue();
    });
  });
}
