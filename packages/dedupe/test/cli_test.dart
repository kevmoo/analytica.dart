import 'dart:convert';
import 'dart:io';

import 'package:analytica/testing.dart';
import 'package:checks/checks.dart';
import 'package:dedupe/dedupe.dart';
import 'package:dedupe/src/cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;
import 'package:test_process/test_process.dart';

void main() {
  late String binPath;

  setUpAll(() async {
    binPath = await resolvePackageExecutable('package:dedupe/dedupe.dart');
  });

  Future<TestProcess> runDedupe(List<String> args, {String? workingDirectory}) {
    return TestProcess.start(Platform.resolvedExecutable, [
      binPath,
      ...args,
    ], workingDirectory: workingDirectory);
  }

  group('Dedupe CLI End-to-End', () {
    test('--help displays usage and exits 0', () async {
      final proc = await runDedupe(['--help']);
      final stdout = await proc.stdoutStream().join('\n');
      await proc.shouldExit(0);

      check(stdout).contains('Usage: dedupe [options] [target_path]');
      check(stdout).contains('--format');
      check(stdout).contains('--min-tokens');
      check(stdout).contains('--min-lines');
      check(stdout).contains('ignore-literals');
      check(stdout).contains('ignore-identifiers');
      check(stdout).contains('ignore-comments');
      check(stdout).contains('--fail-threshold');
      check(stdout).contains('--git-diff');
      check(stdout).contains('only-changed');
      check(stdout).contains('clear-cache');
      check(stdout).contains('cache-dir');
    });

    test('--version displays version and exits 0', () async {
      final proc = await runDedupe(['--version']);
      final stdout = await proc.stdoutStream().join('\n');
      await proc.shouldExit(0);

      check(stdout).contains('dedupe version: $dedupeVersion');
    });

    test('invalid flag exits with code 64 (usage)', () async {
      final proc = await runDedupe(['--nonexistent-flag']);
      await proc.shouldExit(64);
    });

    test('nonexistent path exits with code 66 (noInput)', () async {
      final proc = await runDedupe(['does/not/exist']);
      await proc.shouldExit(66);
    });

    test(
      'runs duplication analysis and outputs JSON with --format=json',
      () async {
        await d.dir('cli_json_pkg', [
          d.dir('lib', [
            d.file('a.dart', '''
void executeTask(int taskId, String payload) {
  if (taskId <= 0) throw ArgumentError('Bad ID');
  print('Running task \$taskId with payload \$payload');
  print('Step 1 complete');
  print('Step 2 complete');
}
'''),
            d.file('b.dart', '''
void executeTask(int taskId, String payload) {
  if (taskId <= 0) throw ArgumentError('Bad ID');
  print('Running task \$taskId with payload \$payload');
  print('Step 1 complete');
  print('Step 2 complete');
}
'''),
          ]),
        ]).create();

        final proc = await runDedupe([
          '--format=json',
          '--min-tokens=15',
          '--min-lines=3',
          d.path('cli_json_pkg'),
        ]);

        final stdout = await proc.stdoutStream().join('\n');
        await proc.shouldExit(0);

        final decoded = jsonDecode(stdout) as Map<String, dynamic>;
        final summary = decoded['summary'] as Map<String, dynamic>;
        check(summary['filesAnalyzed']).equals(2);
        check(summary['clusterCount']).equals(1);

        final clusters = decoded['clusters'] as List<dynamic>;
        check(clusters.length).equals(1);
        final first = clusters.first as Map<String, dynamic>;
        check(first['bucket']).equals('identical');
      },
    );

    test('runs analysis and outputs Markdown with --format=markdown', () async {
      await d.dir('cli_md_pkg', [
        d.dir('lib', [
          d.file('calc_a.dart', '''
int computeScore(int base, int multiplier) {
  if (base < 0) return 0;
  final bonus = multiplier * 10;
  final result = base + bonus;
  return result;
}
'''),
          d.file('calc_b.dart', '''
int computeScore(int base, int multiplier) {
  if (base < 0) return 0;
  final bonus = multiplier * 10;
  final result = base + bonus;
  return result;
}
'''),
        ]),
      ]).create();

      final proc = await runDedupe([
        '--format=markdown',
        '--min-tokens=15',
        '--min-lines=3',
        d.path('cli_md_pkg'),
      ]);

      final stdout = await proc.stdoutStream().join('\n');
      await proc.shouldExit(0);

      check(stdout).contains('# 🔍 Dedupe Duplication Analysis:');
      check(stdout).contains('## 📊 Summary');
      check(stdout).contains('## 📁 File Breakdown');
      check(stdout).contains('## 🔍 Duplicate Clusters');
    });

    test(
      'runs analysis and outputs GitHub format with --format=github',
      () async {
        await d.dir('cli_gh_pkg', [
          d.dir('lib', [
            d.file('calc_a.dart', '''
int computeScore(int base, int multiplier) {
  if (base < 0) return 0;
  final bonus = multiplier * 10;
  final result = base + bonus;
  return result;
}
'''),
            d.file('calc_b.dart', '''
int computeScore(int base, int multiplier) {
  if (base < 0) return 0;
  final bonus = multiplier * 10;
  final result = base + bonus;
  return result;
}
'''),
          ]),
        ]).create();

        final proc = await runDedupe([
          '--format=github',
          '--min-tokens=15',
          '--min-lines=3',
          d.path('cli_gh_pkg'),
        ]);

        final stdout = await proc.stdoutStream().join('\n');
        await proc.shouldExit(0);

        check(stdout).contains('::warning file=lib/calc_a.dart');
        check(stdout).contains('# 🔍 Dedupe Duplication Analysis:');
        check(stdout).contains('## 📊 Summary');
        check(stdout).contains('## 📁 File Breakdown');
        check(stdout).contains('## 🔍 Duplicate Clusters');
      },
    );

    test('--format=github respects --no-files, --no-clusters, --category, and '
        '--bucket', () async {
      await d.dir('cli_gh_filters_pkg', [
        d.dir('lib', [
          d.file('a.dart', '''
int calc(int x) {
  if (x < 0) return 0;
  final a = x * 10;
  final b = a + 5;
  return b;
}
'''),
          d.file('b.dart', '''
int calc(int x) {
  if (x < 0) return 0;
  final a = x * 10;
  final b = a + 5;
  return b;
}
'''),
        ]),
      ]).create();

      // Test --no-files
      final procNoFiles = await runDedupe([
        '--format=github',
        '--no-files',
        '--min-tokens=10',
        '--min-lines=3',
        d.path('cli_gh_filters_pkg'),
      ]);
      final outNoFiles = await procNoFiles.stdoutStream().join('\n');
      await procNoFiles.shouldExit(0);
      check(outNoFiles).not((it) => it.contains('## 📁 File Breakdown'));
      check(outNoFiles).contains('## 📊 Summary');
      check(outNoFiles).contains('::warning');

      // Test --no-clusters
      final procNoClusters = await runDedupe([
        '--format=github',
        '--no-clusters',
        '--min-tokens=10',
        '--min-lines=3',
        d.path('cli_gh_filters_pkg'),
      ]);
      final outNoClusters = await procNoClusters.stdoutStream().join('\n');
      await procNoClusters.shouldExit(0);
      check(outNoClusters).not((it) => it.contains('::warning'));
      check(outNoClusters).not((it) => it.contains('## 🔍 Duplicate Clusters'));
      check(outNoClusters).contains('## 📊 Summary');

      // Test --category=data (when existing cluster is logic)
      final procCategory = await runDedupe([
        '--format=github',
        '--category=data',
        '--min-tokens=10',
        '--min-lines=3',
        d.path('cli_gh_filters_pkg'),
      ]);
      final outCategory = await procCategory.stdoutStream().join('\n');
      await procCategory.shouldExit(0);
      check(outCategory).not((it) => it.contains('::warning'));
      check(
        outCategory,
      ).contains('No duplicate clusters matched the current filter criteria.');

      // Test --bucket=identical
      final procBucket = await runDedupe([
        '--format=github',
        '--bucket=identical',
        '--min-tokens=10',
        '--min-lines=3',
        d.path('cli_gh_filters_pkg'),
      ]);
      final outBucket = await procBucket.stdoutStream().join('\n');
      await procBucket.shouldExit(0);
      check(outBucket).contains('::warning');
      check(outBucket).contains('Identical');
    });

    test('writes JSON report to file with --json-output', () async {
      await d.dir('cli_out_file_pkg', [
        d.dir('lib', [
          d.file('service_a.dart', '''
void runService(String config) {
  if (config.isEmpty) throw ArgumentError();
  print('Connecting to service...');
  print('Executing payload...');
}
'''),
          d.file('service_b.dart', '''
void runService(String config) {
  if (config.isEmpty) throw ArgumentError();
  print('Connecting to service...');
  print('Executing payload...');
}
'''),
        ]),
      ]).create();

      final jsonOutPath = p.join(d.sandbox, 'dedupe_report.json');
      final proc = await runDedupe([
        '--json-output=$jsonOutPath',
        '--min-tokens=15',
        '--min-lines=3',
        d.path('cli_out_file_pkg'),
      ]);

      await proc.shouldExit(0);

      final file = File(jsonOutPath);
      check(file.existsSync()).isTrue();
      final decoded =
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final summary = decoded['summary'] as Map<String, dynamic>;
      check(summary['clusterCount']).equals(1);
    });

    test(
      '--fail-threshold exits with code 1 when threshold is exceeded',
      () async {
        await d.dir('cli_fail_pkg', [
          d.dir('lib', [
            d.file('dup_a.dart', '''
void sharedFunction(int value) {
  if (value < 0) return;
  print('Processing \$value');
  print('Finished');
}
'''),
            d.file('dup_b.dart', '''
void sharedFunction(int value) {
  if (value < 0) return;
  print('Processing \$value');
  print('Finished');
}
'''),
          ]),
        ]).create();

        // Duplication is ~100%, threshold is 5%
        final proc = await runDedupe([
          '--fail-threshold=5',
          '--min-tokens=10',
          '--min-lines=3',
          d.path('cli_fail_pkg'),
        ]);

        await proc.shouldExit(1);
      },
    );

    test(
      '--fail-threshold exits with code 0 when duplication is below threshold',
      () async {
        await d.dir('cli_pass_pkg', [
          d.dir('lib', [
            d.file('unique_a.dart', '''
void uniqueA() {
  print('Alpha 1');
  print('Alpha 2');
}
'''),
            d.file('unique_b.dart', '''
void uniqueB() {
  print('Beta 100');
  print('Beta 200');
}
'''),
          ]),
        ]).create();

        final proc = await runDedupe([
          '--fail-threshold=50',
          d.path('cli_pass_pkg'),
        ]);

        await proc.shouldExit(0);
      },
    );
  });

  group('DedupeCliRunner In-Process', () {
    test('run parses flags and outputs help', () async {
      final runner = DedupeCliRunner();
      final code = await runner.run(['--help']);
      check(code).equals(0);
    });

    test('run parses version flag', () async {
      final runner = DedupeCliRunner();
      final code = await runner.run(['--version']);
      check(code).equals(0);
    });

    test('run reports usage on invalid flag', () async {
      final runner = DedupeCliRunner();
      final code = await runner.run(['--invalid-flag-xyz']);
      check(code).equals(64);
    });

    test('run fails on nonexistent path', () async {
      final runner = DedupeCliRunner();
      final code = await runner.run(['does/not/exist/directory']);
      check(code).equals(66);
    });

    test('run fails when any positional path does not exist', () async {
      await d.dir('in_proc_pkg_valid', [
        d.dir('lib', [d.file('a.dart', 'void main() {}')]),
      ]).create();

      final runner = DedupeCliRunner();
      final code = await runner.run([
        d.path('in_proc_pkg_valid'),
        'does/not/exist/second_dir',
      ]);
      check(code).equals(66);
    });

    test('run reports usage on invalid numeric options', () async {
      final runner = DedupeCliRunner();
      check(await runner.run(['--min-tokens=abc', '.'])).equals(64);
      check(await runner.run(['--min-tokens=-5', '.'])).equals(64);
      check(await runner.run(['--min-lines=foo', '.'])).equals(64);
      check(await runner.run(['--top=xyz', '.'])).equals(64);
      check(await runner.run(['--fail-threshold=-1', '.'])).equals(64);
      check(await runner.run(['--fail-threshold=NaN', '.'])).equals(64);
      check(await runner.run(['--fail-threshold=nan', '.'])).equals(64);
      check(await runner.run(['--fail-threshold=Infinity', '.'])).equals(64);
      check(await runner.run(['--fail-threshold=inf', '.'])).equals(64);
      check(await runner.run(['--fail-threshold=1e400', '.'])).equals(64);
      check(await runner.run(['--fail-threshold=1e309', '.'])).equals(64);
      check(await runner.run(['--fail-threshold=-Infinity', '.'])).equals(64);
    });

    test(
      'run prioritizes flag validation errors over nonexistent paths',
      () async {
        final runner = DedupeCliRunner();
        final code = await runner.run([
          '--min-tokens=abc',
          'does/not/exist/path',
        ]);
        check(code).equals(64);
      },
    );

    test('run executes analysis on temporary directory', () async {
      await d.dir('in_proc_pkg', [
        d.dir('lib', [d.file('a.dart', 'void main() { print("hi"); }')]),
      ]).create();

      final runner = DedupeCliRunner();
      final code = await runner.run(['--format=json', d.path('in_proc_pkg')]);
      check(code).equals(0);
    });

    test(
      'run handles --ignore-comments and --no-ignore-comments flags',
      () async {
        await d.dir('in_proc_comments_pkg', [
          d.dir('lib', [
            d.file('a.dart', '// comment 1\nvoid main() { print("a"); }'),
            d.file('b.dart', '// comment 2\nvoid main() { print("a"); }'),
          ]),
        ]).create();

        final runner = DedupeCliRunner();
        final code1 = await runner.run([
          '--format=json',
          '--ignore-comments',
          d.path('in_proc_comments_pkg'),
        ]);
        check(code1).equals(0);

        final code2 = await runner.run([
          '--format=json',
          '--no-ignore-comments',
          d.path('in_proc_comments_pkg'),
        ]);
        check(code2).equals(0);
      },
    );

    test(
      'run handles --clear-cache, --no-cache, and --cache-dir flags',
      () async {
        await d.dir('in_proc_cache_flags_pkg', [
          d.dir('lib', [d.file('a.dart', 'void main() { print("a"); }')]),
        ]).create();

        final customCache = p.join(d.sandbox, 'custom_cache_dir');
        final runner = DedupeCliRunner();

        final code1 = await runner.run([
          '--format=json',
          '--cache-dir=$customCache',
          d.path('in_proc_cache_flags_pkg'),
        ]);
        check(code1).equals(0);
        check(Directory(customCache).existsSync()).isTrue();

        final code2 = await runner.run([
          '--format=json',
          '--cache-dir=$customCache',
          '--clear-cache',
          d.path('in_proc_cache_flags_pkg'),
        ]);
        check(code2).equals(0);

        final code3 = await runner.run([
          '--format=json',
          '--no-cache',
          d.path('in_proc_cache_flags_pkg'),
        ]);
        check(code3).equals(0);
      },
    );
  });
}
