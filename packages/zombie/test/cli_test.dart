import 'dart:convert';
import 'dart:io';
import 'package:checks/checks.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;
import 'package:test_process/test_process.dart';

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
  final binPath = File('bin/zombie.dart').existsSync()
      ? p.normalize(p.absolute('bin/zombie.dart'))
      : p.normalize(p.absolute('packages/zombie/bin/zombie.dart'));

  Future<TestProcess> runZombie(List<String> args, {String? workingDirectory}) {
    return TestProcess.start(Platform.resolvedExecutable, [
      binPath,
      ...args,
    ], workingDirectory: workingDirectory);
  }

  group('Zombie CLI End-to-End', () {
    test('--help displays usage and exits 0', () async {
      final proc = await runZombie(['--help']);
      final stdout = await proc.stdoutStream().join('\n');
      await proc.shouldExit(0);

      check(stdout).contains('Usage: zombie [options] [target_path]');
      check(stdout).contains('--format');
      check(stdout).contains('--example-mode');
      check(stdout).contains('--mode');
      check(stdout).contains('--pub-get');
      check(stdout).contains('fail-on-zombies');
      check(stdout).contains('workspace-discovery');
    });

    test('--version displays version and exits 0', () async {
      final proc = await runZombie(['--version']);
      final stdout = await proc.stdoutStream().join('\n');
      await proc.shouldExit(0);

      check(stdout).contains('zombie version: 0.1.0');
    });

    test('--mode accepts closed-app', () async {
      await d.dir('mode_pkg', [
        packageConfig('mode_pkg'),
        d.file('pubspec.yaml', '''
name: mode_pkg
environment:
  sdk: '^3.5.0'
'''),
        d.dir('lib', [d.file('main.dart', 'void main() {}')]),
      ]).create();

      final proc = await runZombie(['--mode=closed-app', d.path('mode_pkg')]);
      await proc.shouldExit(0);
    });

    test('invalid argument exits with code 64 (usage)', () async {
      final proc = await runZombie(['--nonexistent-flag']);
      await proc.shouldExit(64);
    });

    test('nonexistent target directory exits with code 66 (noInput)', () async {
      final proc = await runZombie(['does/not/exist']);
      await proc.shouldExit(66);
    });

    test('unresolved package exits with code 78 (config)', () async {
      await d.dir('unresolved_cli_pkg', [
        d.file('pubspec.yaml', '''
name: unresolved_cli_pkg
environment:
  sdk: '^3.5.0'
'''),
        d.dir('lib', [d.file('main.dart', 'void main() {}')]),
      ]).create();

      final proc = await runZombie([d.path('unresolved_cli_pkg')]);
      final stderr = await proc.stderrStream().join('\n');
      await proc.shouldExit(78);

      check(
        stderr,
      ).contains('Resolution Error: Missing .dart_tool/package_config.json');
      check(stderr).contains('Please run "dart pub get"');
    });

    test('runs analysis and outputs JSON with --format=json', () async {
      await d.dir('cli_pkg', [
        packageConfig('cli_pkg'),
        d.file('pubspec.yaml', '''
name: cli_pkg
environment:
  sdk: '^3.5.0'
'''),
        d.dir('lib', [
          d.file('cli_pkg.dart', 'export "src/live.dart";'),
          d.dir('src', [
            d.file('live.dart', 'void live() {}'),
            d.file('dead.dart', 'void dead() {}'),
          ]),
        ]),
      ]).create();

      final proc = await runZombie(['--format=json', d.path('cli_pkg')]);

      final stdout = await proc.stdoutStream().join('\n');
      await proc.shouldExit(0);

      final decoded = jsonDecode(stdout) as Map<String, dynamic>;
      check(decoded['package']).equals('cli_pkg');
      final summary = decoded['summary'] as Map<String, dynamic>;
      check(summary['pureZombies']).equals(1);

      final zombies = decoded['zombies'] as List<dynamic>;
      check(zombies.length).equals(1);
      final firstZombie = zombies.first as Map<String, dynamic>;
      check(firstZombie['name']).equals('dead');
    });

    test('runs analysis and outputs Markdown with --format=markdown', () async {
      await d.dir('cli_md_pkg', [
        packageConfig('cli_md_pkg'),
        d.file('pubspec.yaml', '''
name: cli_md_pkg
environment:
  sdk: '^3.5.0'
'''),
        d.dir('lib', [
          d.file('cli_md_pkg.dart', 'export "src/live.dart";'),
          d.dir('src', [
            d.file('live.dart', 'void live() {}'),
            d.file('dead.dart', 'void dead() {}'),
          ]),
        ]),
      ]).create();

      final proc = await runZombie(['--format=markdown', d.path('cli_md_pkg')]);

      final stdout = await proc.stdoutStream().join('\n');
      await proc.shouldExit(0);

      check(stdout).contains('# Zombie Code Analysis: `cli_md_pkg`');
      check(stdout).contains('## Pure Zombies (Safe to Delete)');
      check(stdout).contains('`dead`');
    });

    test('writes JSON report to file with --json-output', () async {
      await d.dir('cli_json_file_pkg', [
        packageConfig('cli_json_file_pkg'),
        d.file('pubspec.yaml', '''
name: cli_json_file_pkg
environment:
  sdk: '^3.5.0'
'''),
        d.dir('lib', [
          d.file('cli_json_file_pkg.dart', 'export "src/live.dart";'),
          d.dir('src', [
            d.file('live.dart', 'void live() {}'),
            d.file('dead.dart', 'void dead() {}'),
          ]),
        ]),
      ]).create();

      final jsonOutPath = p.join(d.sandbox, 'zombie_out.json');
      final proc = await runZombie([
        '--json-output',
        jsonOutPath,
        d.path('cli_json_file_pkg'),
      ]);

      final stdout = await proc.stdoutStream().join('\n');
      await proc.shouldExit(0);

      // stdout remains human-readable Markdown
      check(stdout).contains('# Zombie Code Analysis: ');

      // json-output file was created and contains valid JSON payload
      final jsonFile = File(jsonOutPath);
      check(jsonFile.existsSync()).isTrue();
      final decoded =
          jsonDecode(jsonFile.readAsStringSync()) as Map<String, dynamic>;
      check(decoded['package']).equals('cli_json_file_pkg');
      final summary = decoded['summary'] as Map<String, dynamic>;
      check(summary['pureZombies']).equals(1);
    });

    test('supports --extra-roots to include companion tests', () async {
      await d.dir('main_pkg', [
        packageConfig('main_pkg'),
        d.file('pubspec.yaml', '''
name: main_pkg
environment:
  sdk: '^3.5.0'
'''),
        d.dir('lib', [
          d.dir('src', [d.file('helper.dart', 'void internalHelper() {}')]),
        ]),
      ]).create();

      await d.dir('companion_test_pkg', [
        d.dir('.dart_tool', [
          d.file('package_config.json', '''
{
  "configVersion": 2,
  "packages": [
    {
      "name": "companion_test_pkg",
      "rootUri": "../",
      "packageUri": "lib/",
      "languageVersion": "3.5"
    },
    {
      "name": "main_pkg",
      "rootUri": "../../main_pkg",
      "packageUri": "lib/",
      "languageVersion": "3.5"
    }
  ]
}
'''),
        ]),
        d.file('companion_test.dart', '''
import 'package:main_pkg/src/helper.dart';

void test(String desc, void Function() body) => body();

void main() {
  test('invokes internal helper', () {
    internalHelper();
  });
}
'''),
      ]).create();

      // Without extra roots, internalHelper is flagged as pure zombie
      final proc1 = await runZombie(['--format=json', d.path('main_pkg')]);
      final out1 = await proc1.stdoutStream().join('\n');
      await proc1.shouldExit(0);
      final json1 = jsonDecode(out1) as Map<String, dynamic>;
      final summary1 = json1['summary'] as Map<String, dynamic>;
      check(summary1['pureZombies']).equals(1);

      // With extra roots, companion_test is treated as a test root
      final proc2 = await runZombie([
        '--format=json',
        '--extra-roots=${d.path('companion_test_pkg')}',
        d.path('main_pkg'),
      ]);
      final out2 = await proc2.stdoutStream().join('\n');
      await proc2.shouldExit(0);
      final json2 = jsonDecode(out2) as Map<String, dynamic>;
      final summary2 = json2['summary'] as Map<String, dynamic>;
      // Now it's reached by tests!
      check(summary2['pureZombies']).equals(0);
      check(summary2['testedZombies']).equals(1);
    });

    test('runs analysis and outputs Markdown with --format=github', () async {
      await d.dir('cli_github_pkg', [
        packageConfig('cli_github_pkg'),
        d.file('pubspec.yaml', '''
name: cli_github_pkg
environment:
  sdk: '^3.5.0'
'''),
        d.dir('lib', [
          d.file('cli_github_pkg.dart', 'export "src/live.dart";'),
          d.dir('src', [
            d.file('live.dart', 'void live() {}'),
            d.file('dead.dart', 'void dead() {}'),
          ]),
        ]),
      ]).create();

      final proc = await runZombie([
        '--format=github',
        d.path('cli_github_pkg'),
      ]);

      final stdout = await proc.stdoutStream().join('\n');
      await proc.shouldExit(0);

      check(stdout).contains('# Zombie Code Analysis: `cli_github_pkg`');
      check(stdout).contains('## Pure Zombies (Safe to Delete)');
    });

    test(
      '--fail-on-zombies exits with code 1 when zombies are found',
      () async {
        await d.dir('cli_fail_pkg', [
          packageConfig('cli_fail_pkg'),
          d.file('pubspec.yaml', '''
name: cli_fail_pkg
environment:
  sdk: '^3.5.0'
'''),
          d.dir('lib', [
            d.file('cli_fail_pkg.dart', 'export "src/live.dart";'),
            d.dir('src', [
              d.file('live.dart', 'void live() {}'),
              d.file('dead.dart', 'void dead() {}'),
            ]),
          ]),
        ]).create();

        final proc = await runZombie([
          '--fail-on-zombies',
          d.path('cli_fail_pkg'),
        ]);

        await proc.shouldExit(1);
      },
    );

    test(
      '--fail-on-zombies exits with code 0 when no zombies are found',
      () async {
        await d.dir('cli_clean_pkg', [
          packageConfig('cli_clean_pkg'),
          d.file('pubspec.yaml', '''
name: cli_clean_pkg
environment:
  sdk: '^3.5.0'
'''),
          d.dir('lib', [
            d.file('cli_clean_pkg.dart', 'export "src/live.dart";'),
            d.dir('src', [d.file('live.dart', 'void live() {}')]),
          ]),
        ]).create();

        final proc = await runZombie([
          '--fail-on-zombies',
          d.path('cli_clean_pkg'),
        ]);

        await proc.shouldExit(0);
      },
    );

    test(
      'supports --no-workspace-discovery to disable workspace discovery',
      () async {
        await d.dir('cli_ws_monorepo', [
          d.dir('.git', []),
          d.dir('packages', [
            d.dir('core_pkg', [
              packageConfig('core_pkg'),
              d.file('pubspec.yaml', '''
name: core_pkg
environment:
  sdk: '^3.5.0'
'''),
              d.dir('lib', [
                d.file('core_pkg.dart', 'export "src/live.dart";'),
                d.dir('src', [
                  d.file('live.dart', 'void live() {}'),
                  d.file('helper.dart', 'void internalHelper() {}'),
                ]),
              ]),
            ]),
            d.dir('consumer_pkg', [
              d.dir('.dart_tool', [
                d.file('package_config.json', '''
{
  "configVersion": 2,
  "packages": [
    {
      "name": "consumer_pkg",
      "rootUri": "../",
      "packageUri": "lib/",
      "languageVersion": "3.5"
    },
    {
      "name": "core_pkg",
      "rootUri": "../../core_pkg",
      "packageUri": "lib/",
      "languageVersion": "3.5"
    }
  ]
}
'''),
              ]),
              d.file('pubspec.yaml', '''
name: consumer_pkg
environment:
  sdk: '^3.5.0'
dependencies:
  core_pkg:
    path: ../core_pkg
'''),
              d.dir('lib', [
                d.file('consumer.dart', '''
import 'package:core_pkg/src/helper.dart';

void useHelper() {
  internalHelper();
}
'''),
              ]),
            ]),
          ]),
        ]).create();

        // 1. By default, workspace discovery is active -> helper is protected
        // (0 pure zombies).
        final proc1 = await runZombie([
          '--format=json',
          d.path('cli_ws_monorepo/packages/core_pkg'),
        ]);
        final out1 = await proc1.stdoutStream().join('\n');
        await proc1.shouldExit(0);
        final json1 = jsonDecode(out1) as Map<String, dynamic>;
        final summary1 = json1['summary'] as Map<String, dynamic>;
        check(summary1['pureZombies']).equals(0);

        // 2. With --no-workspace-discovery, helper is flagged as pure zombie
        final proc2 = await runZombie([
          '--format=json',
          '--no-workspace-discovery',
          d.path('cli_ws_monorepo/packages/core_pkg'),
        ]);
        final out2 = await proc2.stdoutStream().join('\n');
        await proc2.shouldExit(0);
        final json2 = jsonDecode(out2) as Map<String, dynamic>;
        final summary2 = json2['summary'] as Map<String, dynamic>;
        check(summary2['pureZombies']).equals(1);
      },
    );
  });
}
