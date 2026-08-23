import 'package:checks/checks.dart';
import 'package:lower_bound/lower_bound.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

void main() {
  group('PubspecHelper', () {
    test('parses SDK constraint and direct dependency floors', () async {
      await d.dir('sample_pkg', [
        d.file('pubspec.yaml', '''
name: sample_pkg
version: 1.0.0
environment:
  sdk: '>=3.10.0 <4.0.0'
dependencies:
  path: ^1.9.0
  args: '>=2.4.0 <3.0.0'
  meta: 1.15.0
dev_dependencies:
  test: ^1.25.0
'''),
      ]).create();

      final parsed = PubspecHelper.parse(p.join(d.sandbox, 'sample_pkg'));

      check(parsed.name).equals('sample_pkg');
      check(parsed.version).equals(Version(1, 0, 0));
      check(parsed.minSdk).equals(Version(3, 10, 0));
      check(parsed.isPublishable).isTrue();
      check(parsed.isWip).isFalse();
      check(parsed.dependencies).length.equals(3);

      final pathDep = parsed.dependencies.firstWhere((d) => d.name == 'path');
      check(pathDep.lowerBound).equals(Version(1, 9, 0));

      final argsDep = parsed.dependencies.firstWhere((d) => d.name == 'args');
      check(argsDep.lowerBound).equals(Version(2, 4, 0));

      final metaDep = parsed.dependencies.firstWhere((d) => d.name == 'meta');
      check(metaDep.lowerBound).equals(Version(1, 15, 0));
    });

    test('parses wip version and publish_to: none correctly', () async {
      await d.dir('wip_pkg', [
        d.file('pubspec.yaml', '''
name: wip_pkg
version: 0.1.0-wip
publish_to: none
environment:
  sdk: '^3.12.0'
dependencies:
  yaml: ^3.1.2
'''),
      ]).create();

      final parsed = PubspecHelper.parse(p.join(d.sandbox, 'wip_pkg'));
      check(parsed.name).equals('wip_pkg');
      check(parsed.isPublishable).isFalse();
      check(parsed.isWip).isTrue();
      check(parsed.minSdk).equals(Version(3, 12, 0));
    });

    test('throws MissingInputException when pubspec.yaml is missing', () {
      check(
        () => PubspecHelper.parse(p.join(d.sandbox, 'non_existent_dir')),
      ).throws<MissingInputException>();
    });

    test(
      'throws PackageResolutionException when sdk constraint is missing',
      () async {
        await d.dir('no_sdk_pkg', [
          d.file('pubspec.yaml', '''
name: no_sdk_pkg
dependencies:
  path: ^1.9.0
'''),
        ]).create();

        check(
          () => PubspecHelper.parse(p.join(d.sandbox, 'no_sdk_pkg')),
        ).throws<PackageResolutionException>();
      },
    );

    test(
      'finds local sibling packages in a monorepo and identifies wip packages',
      () async {
        await d.dir('monorepo', [
          d.file('pubspec.yaml', '''
name: repo_workspace
workspace:
  - packages/pkg_a
  - packages/pkg_b
  - packages/pkg_c
environment:
  sdk: '^3.12.0'
'''),
          d.dir('packages', [
            d.dir('pkg_a', [
              d.file('pubspec.yaml', '''
name: pkg_a
version: 0.1.0-wip
environment:
  sdk: '^3.12.0'
'''),
            ]),
            d.dir('pkg_b', [
              d.file('pubspec.yaml', '''
name: pkg_b
version: 1.0.0
environment:
  sdk: '^3.12.0'
dependencies:
  pkg_a: ^0.1.0
'''),
            ]),
            d.dir('pkg_c', [
              d.file('pubspec.yaml', '''
name: pkg_c
publish_to: none
environment:
  sdk: '^3.12.0'
'''),
            ]),
          ]),
        ]).create();

        final siblings = PubspecHelper.findLocalSiblings(
          p.join(d.sandbox, 'monorepo', 'packages', 'pkg_b'),
        );

        check(siblings).containsKey('pkg_a');
        check(siblings).containsKey('pkg_b');
        check(siblings).containsKey('pkg_c');

        final pkgA = siblings['pkg_a']!;
        check(pkgA.isWip).isTrue();
        check(pkgA.isPublishToNone).isFalse();

        final pkgB = siblings['pkg_b']!;
        check(pkgB.isWip).isFalse();
        check(pkgB.isPublishToNone).isFalse();

        final pkgC = siblings['pkg_c']!;
        check(pkgC.isPublishToNone).isTrue();
      },
    );
  });
}
