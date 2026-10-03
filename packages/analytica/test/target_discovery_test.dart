import 'package:analytica/analytica.dart';
import 'package:checks/checks.dart';
import 'package:test/scaffolding.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

void main() {
  group('discoverDefaultTargets', () {
    test('single-package repo resolves lib', () async {
      await d.dir('repo', [
        d.file('pubspec.yaml', 'name: single\n'),
        d.dir('lib', [d.file('a.dart', '')]),
        d.dir('test', [d.file('a_test.dart', '')]),
      ]).create();

      check(
        discoverDefaultTargets(rootPath: '${d.sandbox}/repo'),
      ).deepEquals(['lib']);
    });

    test('root workspace: resolves flat sibling member lib dirs', () async {
      await d.dir('repo', [
        d.file('pubspec.yaml', '''
name: ws
workspace:
  - pkg_b
  - pkg_a
  - tool
'''),
        d.dir('pkg_a', [
          d.file('pubspec.yaml', 'name: pkg_a\n'),
          d.dir('lib', [d.file('a.dart', '')]),
          d.dir('test', [d.file('a_test.dart', '')]),
        ]),
        d.dir('pkg_b', [
          d.file('pubspec.yaml', 'name: pkg_b\n'),
          d.dir('lib', [d.file('b.dart', '')]),
        ]),
        // Workspace member without lib/ is skipped.
        d.dir('tool', [
          d.file('pubspec.yaml', 'name: tool\n'),
          d.dir('bin', [d.file('t.dart', '')]),
        ]),
        // Not a workspace member: ignored even though it has lib/.
        d.dir('stray', [
          d.file('pubspec.yaml', 'name: stray\n'),
          d.dir('lib', [d.file('s.dart', '')]),
        ]),
      ]).create();

      check(
        discoverDefaultTargets(rootPath: '${d.sandbox}/repo'),
      ).deepEquals(['pkg_a/lib', 'pkg_b/lib']);
    });

    test('root workspace: includes root lib when present', () async {
      await d.dir('repo', [
        d.file('pubspec.yaml', '''
name: ws
workspace:
  - packages/child
'''),
        d.dir('lib', [d.file('root.dart', '')]),
        d.dir('packages', [
          d.dir('child', [
            d.file('pubspec.yaml', 'name: child\n'),
            d.dir('lib', [d.file('c.dart', '')]),
          ]),
        ]),
      ]).create();

      check(
        discoverDefaultTargets(rootPath: '${d.sandbox}/repo'),
      ).deepEquals(['lib', 'packages/child/lib']);
    });

    test('non-workspace packages/* monorepo resolves packages/*/lib', () async {
      await d.dir('repo', [
        d.dir('packages', [
          d.dir('two', [
            d.file('pubspec.yaml', 'name: two\n'),
            d.dir('lib', [d.file('b.dart', '')]),
            d.dir('test', [d.file('b_test.dart', '')]),
            d.dir('example', [d.file('ex.dart', '')]),
          ]),
          d.dir('one', [
            d.file('pubspec.yaml', 'name: one\n'),
            d.dir('lib', [d.file('a.dart', '')]),
          ]),
        ]),
      ]).create();

      check(
        discoverDefaultTargets(rootPath: '${d.sandbox}/repo'),
      ).deepEquals(['packages/one/lib', 'packages/two/lib']);
    });

    test('pkgs/* and root-level pubspec siblings are discovered', () async {
      await d.dir('repo', [
        d.dir('pkgs', [
          d.dir('p', [
            d.file('pubspec.yaml', 'name: p\n'),
            d.dir('lib', [d.file('p.dart', '')]),
          ]),
        ]),
        d.dir('flat', [
          d.file('pubspec.yaml', 'name: flat\n'),
          d.dir('lib', [d.file('f.dart', '')]),
        ]),
        // No pubspec.yaml: not a package, ignored.
        d.dir('docs', [
          d.dir('lib', [d.file('d.dart', '')]),
        ]),
      ]).create();

      check(
        discoverDefaultTargets(rootPath: '${d.sandbox}/repo'),
      ).deepEquals(['flat/lib', 'pkgs/p/lib']);
    });

    test('falls back to lib when nothing matches', () async {
      await d.dir('repo', [d.file('README.md', '')]).create();

      check(
        discoverDefaultTargets(rootPath: '${d.sandbox}/repo'),
      ).deepEquals(['lib']);
    });

    test('malformed root pubspec falls through to lib', () async {
      await d.dir('repo', [
        d.file('pubspec.yaml', 'workspace: [\n'),
        d.dir('lib', [d.file('a.dart', '')]),
      ]).create();

      check(
        discoverDefaultTargets(rootPath: '${d.sandbox}/repo'),
      ).deepEquals(['lib']);
    });
  });
}
