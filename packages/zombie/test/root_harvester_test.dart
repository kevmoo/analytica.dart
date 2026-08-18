import 'package:checks/checks.dart';
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;
import 'package:zombie/src/models.dart';
import 'package:zombie/src/root_harvester.dart';

d.DirectoryDescriptor packageConfig(String pkgName) {
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
    }
  ]
}
'''),
  ]);
}

void main() {
  group('RootHarvester & PackageTopology', () {
    test(
      'throws PackageResolutionException on missing package_config',
      () async {
        await d.dir('unresolved_pkg', [
          d.file('pubspec.yaml', 'name: unresolved_pkg\n'),
          d.dir('lib', [d.file('unresolved_pkg.dart', 'void foo() {}')]),
        ]).create();

        final options = ZombieOptions(packagePath: d.path('unresolved_pkg'));
        final harvester = RootHarvester(options);

        check(
          harvester.harvestTopology,
        ).throws<PackageResolutionException>().which(
          (it) => it
              .has((e) => e.message, 'message')
              .contains('Missing .dart_tool/package_config.json'),
        );
      },
    );

    test('discovers package directory topology correctly', () async {
      await d.dir('sample_pkg', [
        packageConfig('sample_pkg'),
        d.file('pubspec.yaml', '''
name: sample_pkg
version: 1.0.0
flutter:
  plugin:
    platforms:
      android:
        dartPluginClass: SampleAndroidPlugin
'''),
        d.file('build.yaml', '''
targets:
  \$default:
    builders:
      sample_pkg|builder:
        builder_factories: ["sampleBuilderFactory", "secondaryFactory"]
'''),
        d.dir('lib', [
          d.file('sample_pkg.dart', 'export "src/live.dart";'),
          d.dir('src', [
            d.file('live.dart', 'void live() {}'),
            d.file('generated.g.dart', 'void generated() {}'),
          ]),
        ]),
        d.dir('bin', [d.file('sample_cli.dart', 'void main() {}')]),
        d.dir('example', [d.file('sample_example.dart', 'void main() {}')]),
        d.dir('tool', [d.file('generate.dart', 'void main() {}')]),
        d.dir('test', [d.file('sample_test.dart', 'void main() {}')]),
      ]).create();

      final options = ZombieOptions(
        packagePath: d.path('sample_pkg'),
        includeGenerated: false,
      );

      final harvester = RootHarvester(options);
      final topology = harvester.harvestTopology();

      check(topology.packageName).equals('sample_pkg');
      check(topology.frameworkRoots).contains('SampleAndroidPlugin');
      check(topology.frameworkRoots).contains('sampleBuilderFactory');
      check(topology.frameworkRoots).contains('secondaryFactory');

      check(topology.publicLibFiles).length.equals(1);
      check(topology.internalSrcFiles).length.equals(1); // .g.dart ignored
      check(topology.executableFiles).length.equals(1);
      check(topology.demonstrationFiles).length.equals(1);
      check(topology.auxiliaryFiles).length.equals(1);
      check(topology.testFiles).length.equals(1);

      check(topology.roleOf('lib/sample_pkg.dart')).equals(FileRole.publicLib);
      check(topology.roleOf('lib/src/live.dart')).equals(FileRole.internalSrc);
      check(topology.roleOf('bin/sample_cli.dart')).equals(FileRole.executable);
      check(
        topology.roleOf('example/sample_example.dart'),
      ).equals(FileRole.demonstration);
      check(topology.roleOf('tool/generate.dart')).equals(FileRole.auxiliary);
      check(topology.roleOf('test/sample_test.dart')).equals(FileRole.test);
    });

    test('respects ExampleMode.skip', () async {
      await d.dir('skip_example_pkg', [
        packageConfig('skip_example_pkg'),
        d.file('pubspec.yaml', 'name: skip_example_pkg\n'),
        d.dir('lib', [d.file('main.dart', 'void foo() {}')]),
        d.dir('example', [d.file('demo.dart', 'void main() {}')]),
      ]).create();

      final options = ZombieOptions(
        packagePath: d.path('skip_example_pkg'),
        exampleMode: ExampleMode.skip,
      );

      final harvester = RootHarvester(options);
      final topology = harvester.harvestTopology();

      check(topology.demonstrationFiles).isEmpty();
    });

    test('identifies Flutter entrypoints correctly', () {
      check(PackageTopology.isFlutterEntrypoint('lib/main.dart')).isTrue();
      check(PackageTopology.isFlutterEntrypoint('lib/main_dev.dart')).isTrue();
      check(
        PackageTopology.isFlutterEntrypoint('lib/main_production.dart'),
      ).isTrue();
      check(PackageTopology.isFlutterEntrypoint(r'lib\main.dart')).isTrue();
      check(
        PackageTopology.isFlutterEntrypoint(r'lib\main_prod.dart'),
      ).isTrue();

      check(PackageTopology.isFlutterEntrypoint('lib/src/main.dart')).isFalse();
      check(PackageTopology.isFlutterEntrypoint('bin/main.dart')).isFalse();
      check(PackageTopology.isFlutterEntrypoint('lib/other.dart')).isFalse();
    });

    test('does not exclude lib/src/build/ source directory', () async {
      await d.dir('nested_build_pkg', [
        packageConfig('nested_build_pkg'),
        d.file('pubspec.yaml', 'name: nested_build_pkg\n'),
        d.dir('lib', [
          d.file('nested_build_pkg.dart', 'export "src/build/builder.dart";'),
          d.dir('src', [
            d.dir('build', [d.file('builder.dart', 'void buildHelper() {}')]),
          ]),
        ]),
        d.dir('build', [d.file('output.dart', 'void shouldBeExcluded() {}')]),
      ]).create();

      final options = ZombieOptions(packagePath: d.path('nested_build_pkg'));
      final harvester = RootHarvester(options);
      final topology = harvester.harvestTopology();

      check(topology.internalSrcFiles).contains('lib/src/build/builder.dart');
      check(topology.allFiles).not((it) => it.contains('build/output.dart'));
    });

    test('extracts multi-line YAML builder_factories correctly', () async {
      await d.dir('multiline_build_pkg', [
        packageConfig('multiline_build_pkg'),
        d.file('pubspec.yaml', 'name: multiline_build_pkg\n'),
        d.file('build.yaml', '''
targets:
  \$default:
    builders:
      multiline_build_pkg|builder:
        builder_factories:
          - customBuilderOne
          - 'customBuilderTwo'
'''),
        d.dir('lib', [d.file('main.dart', 'void foo() {}')]),
      ]).create();

      final options = ZombieOptions(packagePath: d.path('multiline_build_pkg'));

      final harvester = RootHarvester(options);
      final topology = harvester.harvestTopology();

      check(topology.frameworkRoots).contains('customBuilderOne');
      check(topology.frameworkRoots).contains('customBuilderTwo');
    });

    test(
      'extracts YAML builder_factories with comments and blank lines (VULN-10)',
      () async {
        await d.dir('commented_build_pkg', [
          packageConfig('commented_build_pkg'),
          d.file('pubspec.yaml', 'name: commented_build_pkg\n'),
          d.file('build.yaml', '''
targets:
  \$default:
    builders:
      commented_build_pkg|builder:
        # Configuration for builder factories
        builder_factories:
          # First factory
          - factoryWithComment

          # Second factory after blank lines
          - "factoryQuoted"
          - 'factorySingleQuoted'
'''),
          d.dir('lib', [d.file('main.dart', 'void foo() {}')]),
        ]).create();

        final options = ZombieOptions(
          packagePath: d.path('commented_build_pkg'),
        );

        final harvester = RootHarvester(options);
        final topology = harvester.harvestTopology();

        check(topology.frameworkRoots).contains('factoryWithComment');
        check(topology.frameworkRoots).contains('factoryQuoted');
        check(topology.frameworkRoots).contains('factorySingleQuoted');
      },
    );

    test('harvests companion roots via workspace discovery', () async {
      await d.dir('harvester_ws', [
        d.dir('.git', []),
        d.dir('packages', [
          d.dir('target_pkg', [
            packageConfig('target_pkg'),
            d.file('pubspec.yaml', 'name: target_pkg\n'),
            d.dir('lib', [d.file('target.dart', 'void main() {}')]),
          ]),
          d.dir('consumer_pkg', [
            packageConfig('consumer_pkg'),
            d.file('pubspec.yaml', '''
name: consumer_pkg
dependencies:
  target_pkg: any
'''),
            d.dir('lib', [d.file('consumer.dart', 'void fn() {}')]),
            d.dir('test', [d.file('consumer_test.dart', 'void fn() {}')]),
          ]),
        ]),
      ]).create();

      final options = ZombieOptions(
        packagePath: d.path('harvester_ws/packages/target_pkg'),
        workspaceDiscovery: true,
      );

      final harvester = RootHarvester(options);
      final topology = harvester.harvestTopology();

      check(topology.extraProductionFiles).length.equals(1);
      check(topology.extraProductionFiles.single).contains('consumer.dart');
      check(topology.extraTestFiles).length.equals(1);
      check(topology.extraTestFiles.single).contains('consumer_test.dart');
    });

    test(
      'harvests explicit .dart file as extraProductionFiles and splits lib/test directories',
      () async {
        await d.dir('harvester_extra_roots', [
          packageConfig('harvester_extra_roots'),
          d.file('pubspec.yaml', 'name: harvester_extra_roots\n'),
          d.dir('lib', [d.file('main.dart', 'void main() {}')]),
        ]).create();

        await d.dir('external_file', [
          d.file('standalone.dart', 'void standalone() {}'),
        ]).create();

        await d.dir('external_dir', [
          d.dir('lib', [d.file('prod.dart', 'void prod() {}')]),
          d.dir('test', [d.file('t.dart', 'void t() {}')]),
        ]).create();

        final options = ZombieOptions(
          packagePath: d.path('harvester_extra_roots'),
          extraRoots: [
            d.path('external_file/standalone.dart'),
            d.path('external_dir'),
          ],
          workspaceDiscovery: false,
        );

        final harvester = RootHarvester(options);
        final topology = harvester.harvestTopology();

        check(
          topology.extraProductionFiles,
        ).length.equals(2); // standalone.dart & prod.dart
        check(topology.extraTestFiles).length.equals(1); // t.dart
      },
    );
  });
}
