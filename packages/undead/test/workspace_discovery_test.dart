import 'package:checks/checks.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;
import 'package:undead/undead.dart';

d.DirectoryDescriptor packageConfig(String pkgName, {String? targetPkgPath}) {
  return d.dir('.dart_tool', [
    d.file('package_config.json', '''
{
  "configVersion": 2,
  "packages": [
    {
      "name": "$pkgName",
      "rootUri": "../",
      "packageUri": "lib/",
      "languageVersion": "3.5"
    }${targetPkgPath != null ? ''',
    {
      "name": "target_pkg",
      "rootUri": "$targetPkgPath",
      "packageUri": "lib/",
      "languageVersion": "3.5"
    }''' : ''}
  ]
}
'''),
  ]);
}

void main() {
  group('WorkspaceConsumerDiscovery', () {
    group('findWorkspaceRoot', () {
      test('locates workspace root via .git directory', () async {
        await d.dir('git_repo', [
          d.dir('.git', []),
          d.dir('packages', [
            d.dir('pkg_a', [d.file('pubspec.yaml', 'name: pkg_a\n')]),
          ]),
        ]).create();

        const discovery = WorkspaceConsumerDiscovery();
        final root = discovery.findWorkspaceRoot(
          d.path('git_repo/packages/pkg_a'),
        );
        check(root).equals(p.normalize(d.path('git_repo')));
      });

      test(
        'locates workspace root via .git file (worktree/submodule)',
        () async {
          await d.dir('git_worktree_repo', [
            d.file('.git', 'gitdir: /path/to/main/.git/worktrees/wt'),
            d.dir('packages', [
              d.dir('pkg_a', [d.file('pubspec.yaml', 'name: pkg_a\n')]),
            ]),
          ]).create();

          const discovery = WorkspaceConsumerDiscovery();
          final root = discovery.findWorkspaceRoot(
            d.path('git_worktree_repo/packages/pkg_a'),
          );
          check(root).equals(p.normalize(d.path('git_worktree_repo')));
        },
      );

      test('locates workspace root via DEPS file (Chromium/Engine)', () async {
        await d.dir('engine_repo', [
          d.file('DEPS', 'vars = {}'),
          d.dir('src', [
            d.dir('flutter', [
              d.dir('lib', [
                d.dir('web_ui', [d.file('pubspec.yaml', 'name: web_ui\n')]),
              ]),
            ]),
          ]),
        ]).create();

        const discovery = WorkspaceConsumerDiscovery();
        final root = discovery.findWorkspaceRoot(
          d.path('engine_repo/src/flutter/lib/web_ui'),
        );
        check(root).equals(p.normalize(d.path('engine_repo')));
      });

      test('locates workspace root via .gclient file', () async {
        await d.dir('gclient_repo', [
          d.file('.gclient', 'solutions = []'),
          d.dir('src', [
            d.dir('pkg_a', [d.file('pubspec.yaml', 'name: pkg_a\n')]),
          ]),
        ]).create();

        const discovery = WorkspaceConsumerDiscovery();
        final root = discovery.findWorkspaceRoot(
          d.path('gclient_repo/src/pkg_a'),
        );
        check(root).equals(p.normalize(d.path('gclient_repo')));
      });

      test(
        'locates workspace root via pubspec.yaml with workspace: key',
        () async {
          await d.dir('pub_workspace', [
            d.file('pubspec.yaml', '''
name: root_workspace
workspace:
  - packages/pkg_a
  - packages/pkg_b
'''),
            d.dir('packages', [
              d.dir('pkg_a', [
                d.file('pubspec.yaml', '''
name: pkg_a
resolution: workspace
'''),
              ]),
            ]),
          ]).create();

          const discovery = WorkspaceConsumerDiscovery();
          final root = discovery.findWorkspaceRoot(
            d.path('pub_workspace/packages/pkg_a'),
          );
          check(root).equals(p.normalize(d.path('pub_workspace')));
        },
      );
    });

    group('discoverConsumers', () {
      test('discovers sibling packages referencing target via path and '
          'workspace dependencies', () async {
        await d.dir('monorepo', [
          d.dir('.git', []),
          d.dir('packages', [
            d.dir('target_pkg', [
              packageConfig('target_pkg'),
              d.file('pubspec.yaml', '''
name: target_pkg
environment:
  sdk: '^3.5.0'
'''),
              d.dir('lib', [
                d.file('target_pkg.dart', 'void publicFunc() {}'),
                d.dir('src', [
                  d.file('helper.dart', 'void internalHelper() {}'),
                ]),
              ]),
            ]),
            d.dir('consumer_prod', [
              packageConfig('consumer_prod', targetPkgPath: '../../target_pkg'),
              d.file('pubspec.yaml', '''
name: consumer_prod
environment:
  sdk: '^3.5.0'
dependencies:
  target_pkg:
    path: ../target_pkg
'''),
              d.dir('lib', [
                d.file('consumer.dart', 'void prodConsumer() {}'),
                d.file('other.dart', 'void otherProd() {}'),
              ]),
              d.dir('test', [
                d.file('consumer_test.dart', 'void testProd() {}'),
              ]),
            ]),
            d.dir('consumer_dev', [
              packageConfig('consumer_dev', targetPkgPath: '../../target_pkg'),
              d.file('pubspec.yaml', '''
name: consumer_dev
environment:
  sdk: '^3.5.0'
dev_dependencies:
  target_pkg:
    path: ../target_pkg
'''),
              d.dir('lib', [d.file('dev_lib.dart', 'void devLib() {}')]),
              d.dir('test', [d.file('dev_test.dart', 'void devTest() {}')]),
            ]),
            d.dir('unrelated_pkg', [
              packageConfig('unrelated_pkg'),
              d.file('pubspec.yaml', '''
name: unrelated_pkg
environment:
  sdk: '^3.5.0'
dependencies:
  path: ^1.9.0
'''),
              d.dir('lib', [d.file('unrelated.dart', 'void unrelated() {}')]),
            ]),
          ]),
        ]).create();

        const discovery = WorkspaceConsumerDiscovery();
        final roots = discovery.discoverConsumers(
          packagePath: d.path('monorepo/packages/target_pkg'),
        );

        check(roots.isNotEmpty).isTrue();

        // Dual Root Ingestion:
        // lib/ files in consumer_prod and consumer_dev -> productionRoots
        final prodNorm = roots.productionRoots.map(p.normalize).toList();
        check(prodNorm).contains(
          p.normalize(
            d.path('monorepo/packages/consumer_prod/lib/consumer.dart'),
          ),
        );
        check(prodNorm).contains(
          p.normalize(d.path('monorepo/packages/consumer_prod/lib/other.dart')),
        );
        check(prodNorm).contains(
          p.normalize(
            d.path('monorepo/packages/consumer_dev/lib/dev_lib.dart'),
          ),
        );
        check(prodNorm).not(
          (c) => c.contains(
            p.normalize(
              d.path('monorepo/packages/unrelated_pkg/lib/unrelated.dart'),
            ),
          ),
        );

        // test/ files in consumer_prod and consumer_dev -> testRoots
        final testNorm = roots.testRoots.map(p.normalize).toList();
        check(testNorm).contains(
          p.normalize(
            d.path('monorepo/packages/consumer_prod/test/consumer_test.dart'),
          ),
        );
        check(testNorm).contains(
          p.normalize(
            d.path('monorepo/packages/consumer_dev/test/dev_test.dart'),
          ),
        );
      });

      test(
        'skips sibling package if .dart_tool/package_config.json is missing',
        () async {
          await d.dir('missing_config_repo', [
            d.dir('.git', []),
            d.dir('packages', [
              d.dir('target_pkg', [
                packageConfig('target_pkg'),
                d.file('pubspec.yaml', 'name: target_pkg\n'),
                d.dir('lib', [d.file('target.dart', 'void fn() {}')]),
              ]),
              d.dir('unresolved_consumer', [
                // No .dart_tool/package_config.json
                d.file('pubspec.yaml', '''
name: unresolved_consumer
dependencies:
  target_pkg:
    path: ../target_pkg
'''),
                d.dir('lib', [d.file('unresolved.dart', 'void fn() {}')]),
              ]),
            ]),
          ]).create();

          const discovery = WorkspaceConsumerDiscovery();
          final roots = discovery.discoverConsumers(
            packagePath: d.path('missing_config_repo/packages/target_pkg'),
          );

          check(roots.isEmpty).isTrue();
        },
      );

      test('respects directory exclusions and maxDepth', () async {
        await d.dir('excluded_repo', [
          d.dir('.git', []),
          d.dir('packages', [
            d.dir('target_pkg', [
              packageConfig('target_pkg'),
              d.file('pubspec.yaml', 'name: target_pkg\n'),
              d.dir('lib', [d.file('target.dart', 'void fn() {}')]),
            ]),
            d.dir('build', [
              d.dir('nested_consumer', [
                packageConfig('nested_consumer'),
                d.file('pubspec.yaml', '''
name: nested_consumer
dependencies:
  target_pkg: any
'''),
                d.dir('lib', [d.file('built.dart', 'void fn() {}')]),
              ]),
            ]),
            d.dir('example', [
              d.dir('demo_consumer', [
                packageConfig('demo_consumer'),
                d.file('pubspec.yaml', '''
name: demo_consumer
dependencies:
  target_pkg: any
'''),
                d.dir('lib', [d.file('demo.dart', 'void fn() {}')]),
              ]),
            ]),
            d.dir('level1', [
              d.dir('level2', [
                d.dir('level3', [
                  d.dir('level4', [
                    d.dir('level5', [
                      d.dir('deep_consumer', [
                        packageConfig('deep_consumer'),
                        d.file('pubspec.yaml', '''
name: deep_consumer
dependencies:
  target_pkg: any
'''),
                        d.dir('lib', [d.file('deep.dart', 'void fn() {}')]),
                      ]),
                    ]),
                  ]),
                ]),
              ]),
            ]),
          ]),
        ]).create();

        const discovery = WorkspaceConsumerDiscovery(maxDepth: 3);
        final roots = discovery.discoverConsumers(
          packagePath: d.path('excluded_repo/packages/target_pkg'),
        );

        check(roots.isEmpty).isTrue();
      });

      test('collects files inside lib/src/build/ and other subdirectories '
          'without false exclusion', () async {
        await d.dir('nested_build_repo', [
          d.dir('.git', []),
          d.dir('packages', [
            d.dir('target_pkg', [
              packageConfig('target_pkg'),
              d.file('pubspec.yaml', 'name: target_pkg\n'),
              d.dir('lib', [d.file('target.dart', 'void targetFn() {}')]),
            ]),
            d.dir('consumer_with_build_dir', [
              packageConfig(
                'consumer_with_build_dir',
                targetPkgPath: '../../target_pkg',
              ),
              d.file('pubspec.yaml', '''
name: consumer_with_build_dir
dependencies:
  target_pkg:
    path: ../target_pkg
'''),
              d.dir('lib', [
                d.dir('src', [
                  d.dir('build', [
                    d.file('code_generator.dart', 'void gen() {}'),
                  ]),
                ]),
              ]),
              d.dir('test', [
                d.dir('build', [
                  d.file('generator_test.dart', 'void testGen() {}'),
                ]),
              ]),
            ]),
          ]),
        ]).create();

        const discovery = WorkspaceConsumerDiscovery();
        final roots = discovery.discoverConsumers(
          packagePath: d.path('nested_build_repo/packages/target_pkg'),
        );

        final prodNorm = roots.productionRoots.map(p.normalize).toList();
        check(prodNorm).contains(
          p.normalize(
            d.path(
              'nested_build_repo/packages/consumer_with_build_dir/lib/src/build/code_generator.dart',
            ),
          ),
        );

        final testNorm = roots.testRoots.map(p.normalize).toList();
        check(testNorm).contains(
          p.normalize(
            d.path(
              'nested_build_repo/packages/consumer_with_build_dir/test/build/generator_test.dart',
            ),
          ),
        );
      });

      test(
        'discovers sibling referencing target via dependency_overrides',
        () async {
          await d.dir('overrides_repo', [
            d.dir('.git', []),
            d.dir('packages', [
              d.dir('target_pkg', [
                packageConfig('target_pkg'),
                d.file('pubspec.yaml', 'name: target_pkg\n'),
                d.dir('lib', [d.file('target.dart', 'void targetFn() {}')]),
              ]),
              d.dir('override_consumer', [
                packageConfig(
                  'override_consumer',
                  targetPkgPath: '../../target_pkg',
                ),
                d.file('pubspec.yaml', '''
name: override_consumer
dependency_overrides:
  target_pkg:
    path: ../target_pkg
'''),
                d.dir('lib', [d.file('override_lib.dart', 'void libFn() {}')]),
              ]),
            ]),
          ]).create();

          const discovery = WorkspaceConsumerDiscovery();
          final roots = discovery.discoverConsumers(
            packagePath: d.path('overrides_repo/packages/target_pkg'),
          );

          final prodNorm = roots.productionRoots.map(p.normalize).toList();
          check(prodNorm).contains(
            p.normalize(
              d.path(
                'overrides_repo/packages/override_consumer/lib/override_lib.dart',
              ),
            ),
          );
        },
      );
    });
  });
}
