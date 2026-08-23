import 'package:checks/checks.dart';
import 'package:lower_bound/lower_bound.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

void main() {
  group('LowerBoundRunner Integration', () {
    test('trivially passes for packages with no dependencies', () async {
      await d.dir('no_deps', [
        d.file('pubspec.yaml', '''
name: no_deps
environment:
  sdk: '^3.12.0'
'''),
        d.dir('lib', [d.file('no_deps.dart', 'const answer = 42;')]),
      ]).create();

      final res = await LowerBoundRunner.validate(
        packagePath: p.join(d.sandbox, 'no_deps'),
      );

      check(res.isClean).isTrue();
      check(res.dependencies).isEmpty();
      check(res.pubGetSuccess).isTrue();
      check(res.analyzeSuccess).isTrue();
    });

    test('validates package with clean dependency floor', () async {
      await d.dir('clean_pkg', [
        d.file('pubspec.yaml', '''
name: clean_pkg
environment:
  sdk: '^3.12.0'
dependencies:
  path: ^1.9.0
'''),
        d.dir('lib', [
          d.file('clean_pkg.dart', '''
import 'package:path/path.dart' as p;

String joinPaths(String a, String b) => p.join(a, b);
'''),
        ]),
      ]).create();

      final res = await LowerBoundRunner.validate(
        packagePath: p.join(d.sandbox, 'clean_pkg'),
      );

      check(res.isClean).isTrue();
      check(res.dependencies).length.equals(1);
      check(res.dependencies.first.name).equals('path');
      check(res.dependencies.first.lowerBound).equals(Version(1, 9, 0));
      check(res.resolvedVersions['path']).equals(Version(1, 9, 0));
    });

    test(
      'detects analysis failure when code uses API missing at floor',
      () async {
        await d.dir('broken_pkg', [
          d.file('pubspec.yaml', '''
name: broken_pkg
environment:
  sdk: '^3.12.0'
dependencies:
  path: ^1.9.0
'''),
          d.dir('lib', [
            d.file('broken_pkg.dart', '''
import 'package:path/path.dart' as p;

// Calling non-existent function on path package
void broken() {
  p.thisFunctionDoesNotExistAtFloor();
}
'''),
          ]),
        ]).create();

        final res = await LowerBoundRunner.validate(
          packagePath: p.join(d.sandbox, 'broken_pkg'),
        );

        check(res.isClean).isFalse();
        check(res.pubGetSuccess).isTrue();
        check(res.analyzeSuccess).isFalse();
        check(res.analyzerErrors).isNotEmpty();
      },
    );
  });
}
