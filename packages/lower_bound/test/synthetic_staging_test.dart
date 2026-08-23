import 'dart:io';

import 'package:checks/checks.dart';
import 'package:lower_bound/lower_bound.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

void main() {
  group('SyntheticStaging', () {
    test(
      'copies lib and bin, sanitizes analysis options, strips dev_dependencies',
      () async {
        await d.dir('staging_test', [
          d.file('pubspec.yaml', '''
name: staging_test
resolution: workspace
environment:
  sdk: '^3.12.0'
dependencies:
  path: ^1.9.0
dev_dependencies:
  test: ^1.25.0
'''),
          d.dir('lib', [d.file('staging_test.dart', 'void hello() {}')]),
          d.dir('bin', [d.file('tool.dart', 'void main() {}')]),
          d.file('analysis_options.yaml', '''
include: package:dart_flutter_team_lints/analysis_options.yaml
analyzer:
  language:
    strict-casts: true
'''),
        ]).create();

        final parsed = parsePubspec(p.join(d.sandbox, 'staging_test'));
        final staging = SyntheticStaging.create(
          sourcePackagePath: p.join(d.sandbox, 'staging_test'),
          pubspec: parsed,
        );

        try {
          check(
            File(
              p.join(staging.stagingDir.path, 'lib', 'staging_test.dart'),
            ).existsSync(),
          ).isTrue();
          check(
            File(
              p.join(staging.stagingDir.path, 'bin', 'tool.dart'),
            ).existsSync(),
          ).isTrue();

          staging.writePubspec(pinLowerBounds: true);

          final stagedPubspecContent = File(
            p.join(staging.stagingDir.path, 'pubspec.yaml'),
          ).readAsStringSync();

          check(stagedPubspecContent).contains('name: staging_test');
          check(stagedPubspecContent).contains('publish_to: none');
          check(stagedPubspecContent).contains('path: \'^1.9.0\'');
          check(stagedPubspecContent).contains('dependency_overrides:');
          check(stagedPubspecContent).contains('path: \'1.9.0\'');
          check(
            stagedPubspecContent,
          ).not((c) => c.contains('resolution: workspace'));
          check(
            stagedPubspecContent,
          ).not((c) => c.contains('dev_dependencies'));

          final stagedOptions = File(
            p.join(staging.stagingDir.path, 'analysis_options.yaml'),
          ).readAsStringSync();
          check(stagedOptions).contains('strict-casts: true');
          check(stagedOptions).contains('# [lower_bound stripped include:');
        } finally {
          staging.dispose();
        }
      },
    );

    test('links unreleased wip local siblings via path overrides', () async {
      await d.dir('sibling_repo', [
        d.dir('pkg_a', [
          d.file('pubspec.yaml', '''
name: pkg_a
version: 0.1.0-wip
environment:
  sdk: '^3.12.0'
'''),
          d.dir('lib', [d.file('pkg_a.dart', 'const a = 1;')]),
        ]),
        d.dir('pkg_b', [
          d.file('pubspec.yaml', '''
name: pkg_b
version: 1.0.0
environment:
  sdk: '^3.12.0'
dependencies:
  pkg_a: ^0.1.0
  path: ^1.9.0
'''),
          d.dir('lib', [
            d.file('pkg_b.dart', 'import "package:pkg_a/pkg_a.dart";'),
          ]),
        ]),
      ]).create();

      final pkgBPath = p.join(d.sandbox, 'sibling_repo', 'pkg_b');
      final parsed = parsePubspec(pkgBPath);

      final localSiblings = {
        'pkg_a': LocalSibling(
          name: 'pkg_a',
          path: p.join(d.sandbox, 'sibling_repo', 'pkg_a'),
          version: Version(0, 1, 0, pre: 'wip'),
          rawVersion: '0.1.0-wip',
          isWip: true,
          isPublishToNone: false,
        ),
      };

      final staging = SyntheticStaging.create(
        sourcePackagePath: pkgBPath,
        pubspec: parsed,
        localSiblings: localSiblings,
      );

      try {
        staging.writePubspec(pinLowerBounds: true);

        final stagedPubspecContent = File(
          p.join(staging.stagingDir.path, 'pubspec.yaml'),
        ).readAsStringSync();

        check(stagedPubspecContent).contains('dependency_overrides:');
        check(stagedPubspecContent).contains('path: \'1.9.0\'');
        check(stagedPubspecContent).contains('pkg_a:');
        check(stagedPubspecContent).contains('path: \'');

        check(staging.warnings).length.equals(1);
        check(staging.warnings.first).contains('unreleased local sibling');
      } finally {
        staging.dispose();
      }
    });

    test('reads resolved versions from package_config.json', () async {
      await d.dir('pkg_config_test', [
        d.file('pubspec.yaml', '''
name: pkg_config_test
environment:
  sdk: '^3.12.0'
dependencies:
  path: ^1.9.0
'''),
        d.dir('lib', [d.file('pkg_config_test.dart', '')]),
      ]).create();

      final parsed = parsePubspec(p.join(d.sandbox, 'pkg_config_test'));
      final staging = SyntheticStaging.create(
        sourcePackagePath: p.join(d.sandbox, 'pkg_config_test'),
        pubspec: parsed,
      );

      try {
        final dotDartTool = Directory(
          p.join(staging.stagingDir.path, '.dart_tool'),
        )..createSync(recursive: true);

        File(p.join(dotDartTool.path, 'package_config.json')).writeAsStringSync(
          '''
{
  "configVersion": 2,
  "packages": [
    {
      "name": "path",
      "rootUri": "file:///pub-cache/hosted/pub.dev/path-1.9.0",
      "packageUri": "lib/"
    }
  ]
}
''',
        );

        final versions = staging.readResolvedVersions();
        check(versions).containsKey('path');
        check(versions['path']).equals('1.9.0');
      } finally {
        staging.dispose();
      }
    });
  });
}
