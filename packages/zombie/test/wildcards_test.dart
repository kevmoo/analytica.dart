import 'dart:convert';
import 'dart:io';
import 'package:checks/checks.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;
import 'package:test_process/test_process.dart';
import 'package:zombie/zombie.dart';

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

  group('Wildcards & Pattern Filtering', () {
    group('ReachabilityEngine - ignoreNamePatterns', () {
      test(
        'skips dead declarations matching ignoreNamePatterns wildcards',
        () async {
          await d.dir('ignore_patterns_pkg', [
            packageConfig('ignore_patterns_pkg'),
            d.file('pubspec.yaml', '''
name: ignore_patterns_pkg
environment:
  sdk: '^3.5.0'
'''),
            d.dir('lib', [
              d.file('ignore_patterns_pkg.dart', 'export "src/live.dart";'),
              d.dir('src', [
                d.file('live.dart', 'void liveFunc() {}'),
                d.file('dead.dart', '''
void helper_generated() {}
void IgnoredService() {}
void trulyDeadFunc() {}
'''),
              ]),
            ]),
          ]).create();

          // 1. Without ignoreNamePatterns: all 3 dead declarations are flagged.
          final reportDefault = await analyzePackage(
            d.path('ignore_patterns_pkg'),
          );
          check(reportDefault.pureZombiesFound).equals(3);

          // 2. With ignoreNamePatterns: '*_generated' and 'Ignored*' are
          // skipped.
          final options = ZombieOptions(
            packagePath: d.path('ignore_patterns_pkg'),
            ignoreNamePatterns: const ['*_generated', 'Ignored*'],
          );
          final reportFiltered = await analyzePackage(
            d.path('ignore_patterns_pkg'),
            options: options,
          );

          check(reportFiltered.pureZombiesFound).equals(1);
          final zombie = reportFiltered.zombies.single;
          check(zombie.name).equals('trulyDeadFunc');
        },
      );
    });

    group('ReachabilityEngine - testSupportPatterns', () {
      test(
        'preserves custom test support patterns when reached by test roots',
        () async {
          await d.dir('custom_test_support_pkg', [
            packageConfig('custom_test_support_pkg'),
            d.file('pubspec.yaml', '''
name: custom_test_support_pkg
environment:
  sdk: '^3.5.0'
'''),
            d.dir('lib', [
              d.file('custom_test_support_pkg.dart', 'export "src/live.dart";'),
              d.dir('src', [
                d.file('live.dart', 'class LiveClass {}'),
                d.file('fixtures.dart', '''
class DatabaseStub {
  void reset() {}
}

class UnusedStub {
  void reset() {}
}

class RegularDeadClass {
  void run() {}
}
'''),
              ]),
            ]),
            d.dir('test', [
              d.file('service_test.dart', '''
import 'package:custom_test_support_pkg/src/fixtures.dart';

void test(String desc, Function body) {}

void main() {
  test('uses stub and regular dead class', () {
    final stub = DatabaseStub();
    stub.reset();

    final dead = RegularDeadClass();
    dead.run();
  });
}
'''),
            ]),
          ]).create();

          // 1. Default patterns: DatabaseStub is not recognized as test support
          // (by default Fake*/Mock*), so DatabaseStub and RegularDeadClass are
          // tested zombies, and UnusedStub is pure zombie.
          final reportDefault = await analyzePackage(
            d.path('custom_test_support_pkg'),
          );
          check(reportDefault.pureZombiesFound).equals(1); // UnusedStub
          check(
            reportDefault.testedZombiesFound,
          ).equals(2); // DatabaseStub, RegularDeadClass

          // 2. Custom patterns: '*Stub' is configured as test support.
          // DatabaseStub (reached by tests) is preserved as test support.
          // RegularDeadClass is still a tested zombie.
          // UnusedStub (unreached by tests) is still a pure zombie.
          final options = ZombieOptions(
            packagePath: d.path('custom_test_support_pkg'),
            testSupportPatterns: const ['*Stub'],
          );
          final reportCustom = await analyzePackage(
            d.path('custom_test_support_pkg'),
            options: options,
          );

          check(reportCustom.pureZombiesFound).equals(1);
          check(reportCustom.testedZombiesFound).equals(1);

          final pureZombie = reportCustom.zombies.firstWhere(
            (z) => z.classification == ZombieClassification.pureZombie,
          );
          check(pureZombie.name).equals('UnusedStub');

          final testedZombie = reportCustom.zombies.firstWhere(
            (z) => z.classification == ZombieClassification.testedZombie,
          );
          check(testedZombie.name).equals('RegularDeadClass');
        },
      );
    });

    group('CLI Integration', () {
      test('--help displays new wildcard options', () async {
        final proc = await runZombie(['--help']);
        final stdout = await proc.stdoutStream().join('\n');
        await proc.shouldExit(0);

        check(stdout).contains('--test-support-patterns');
        check(stdout).contains('--ignore-name-patterns');
      });

      test(
        'applies --ignore-name-patterns and --test-support-patterns CLI flags',
        () async {
          await d.dir('cli_wildcards_pkg', [
            packageConfig('cli_wildcards_pkg'),
            d.file('pubspec.yaml', '''
name: cli_wildcards_pkg
environment:
  sdk: '^3.5.0'
'''),
            d.dir('lib', [
              d.file('cli_wildcards_pkg.dart', 'export "src/live.dart";'),
              d.dir('src', [
                d.file('live.dart', 'void live() {}'),
                d.file('stuff.dart', '''
void gen_helper() {}
void real_dead() {}
class NetworkStub {
  void ping() {}
}
'''),
              ]),
            ]),
            d.dir('test', [
              d.file('stuff_test.dart', '''
import 'package:cli_wildcards_pkg/src/stuff.dart';

void test(String desc, Function body) {}

void main() {
  test('uses network stub', () {
    final stub = NetworkStub();
    stub.ping();
  });
}
'''),
            ]),
          ]).create();

          final proc = await runZombie([
            '--format=json',
            '--ignore-name-patterns=gen_*',
            '--test-support-patterns=*Stub',
            d.path('cli_wildcards_pkg'),
          ]);

          final stdout = await proc.stdoutStream().join('\n');
          await proc.shouldExit(0);

          final json = jsonDecode(stdout) as Map<String, dynamic>;
          final summary = json['summary'] as Map<String, dynamic>;
          check(summary['pureZombies']).equals(1);
          check(summary['testedZombies']).equals(0);

          final zombies = json['zombies'] as List<dynamic>;
          check(zombies.length).equals(1);
          final firstZombie = zombies.first as Map<String, dynamic>;
          check(firstZombie['name']).equals('real_dead');
        },
      );

      test(
        'handles whitespace and empty elements in comma-separated CLI flags',
        () async {
          await d.dir('cli_whitespace_pkg', [
            packageConfig('cli_whitespace_pkg'),
            d.file('pubspec.yaml', '''
name: cli_whitespace_pkg
environment:
  sdk: '^3.5.0'
'''),
            d.dir('lib', [
              d.file('cli_whitespace_pkg.dart', 'export "src/live.dart";'),
              d.dir('src', [
                d.file('live.dart', 'void live() {}'),
                d.file('dead.dart', '''
void _ignored_a() {}
void _ignored_b() {}
void actual_dead() {}
'''),
              ]),
            ]),
          ]).create();

          final proc = await runZombie([
            '--format=json',
            '--ignore-name-patterns=_ignored_a,  , _ignored_b',
            d.path('cli_whitespace_pkg'),
          ]);

          final stdout = await proc.stdoutStream().join('\n');
          await proc.shouldExit(0);

          final json = jsonDecode(stdout) as Map<String, dynamic>;
          final summary = json['summary'] as Map<String, dynamic>;
          check(summary['pureZombies']).equals(1);

          final zombies = json['zombies'] as List<dynamic>;
          check(zombies.length).equals(1);
          check(
            (zombies.first as Map<String, dynamic>)['name'],
          ).equals('actual_dead');
        },
      );
    });
  });
}
