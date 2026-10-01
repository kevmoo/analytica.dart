import 'dart:io';

import 'package:analytica/testing.dart';
import 'package:checks/checks.dart';
import 'package:test/scaffolding.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;
import 'package:test_process/test_process.dart';

void main() {
  late String binPath;

  setUpAll(() async {
    binPath = await resolvePackageExecutable(
      'package:cognitive_complexity/cognitive_complexity.dart',
    );
  });

  group('CLI Integration Tests', () {
    test('Calculates complexity and displays text table report', () async {
      await d.dir('project', [
        d.dir('lib', [
          d.file('sample.dart', '''
int compute(int x) {
  if (x > 0) {
    if (x > 10) {
      return 2;
    }
    return 1;
  }
  return 0;
}
'''),
        ]),
      ]).create();

      final process = await TestProcess.start(Platform.resolvedExecutable, [
        binPath,
        '${d.sandbox}/project',
      ]);

      await check(
        process.stdout,
      ).emitsThrough((s) => s.contains('Score  Declaration'));
      await check(process.stdout).emitsThrough((s) => s.contains('3  compute'));
      await process.shouldExit(0);
    });

    test(
      'Outputs clean JSON formatted array when --format json is requested',
      () async {
        await d.dir('project_json', [
          d.dir('lib', [
            d.file('service.dart', '''
class MyService {
  void handle(bool flag) {
    if (flag) {
      print('ok');
    }
  }
}
'''),
          ]),
        ]).create();

        final process = await TestProcess.start(Platform.resolvedExecutable, [
          binPath,
          '--format',
          'json',
          '${d.sandbox}/project_json',
        ]);

        await check(process.stdout).emitsThrough(
          (s) => s
            ..contains('"name":"MyService.handle"')
            ..contains('"score":1'),
        );
        await process.shouldExit(0);
      },
    );

    test('Exits with code 1 when --fail-threshold is exceeded', () async {
      await d.dir('project_fail', [
        d.dir('lib', [
          d.file('bad_func.dart', '''
void complexFunc(int a) {
  if (a > 1) {
    if (a > 2) {
      if (a > 3) {
        print(a);
      }
    }
  }
}
'''),
        ]),
      ]).create();

      final process = await TestProcess.start(Platform.resolvedExecutable, [
        binPath,
        '--fail-threshold',
        '2',
        '${d.sandbox}/project_fail',
      ]);

      await check(
        process.stdout,
      ).emitsThrough((s) => s.contains('[VIOLATION]'));
      await check(
        process.stderr,
      ).emitsThrough((s) => s.contains('exceeded the failure threshold (2)'));
      await process.shouldExit(1);
    });

    test('Supports opt-in --max-file-lines and --max-function-lines across '
        'text, json, and github formats', () async {
      final generatedBody = List.generate(
        25,
        (i) => '  final x$i = $i;',
      ).join('\n');
      await d.dir('project_lines', [
        d.dir('lib', [
          d.file('long_file.dart', 'void bigDecl() {\n$generatedBody\n}\n'),
        ]),
      ]).create();

      final target = '${d.sandbox}/project_lines/lib/long_file.dart';

      // 1. Default run (limits disabled) exits 0 and JSON is a bare list
      final defaultJsonProc = await TestProcess.start(
        Platform.resolvedExecutable,
        [binPath, '--format', 'json', target],
      );
      final defaultJsonLine = await defaultJsonProc.stdout.next;
      check(defaultJsonLine.startsWith('[')).isTrue();
      await defaultJsonProc.shouldExit(0);

      // 2. --max-file-lines in JSON format emits declarations + files object
      final fileJsonProc = await TestProcess.start(
        Platform.resolvedExecutable,
        [binPath, '--max-file-lines', '15', '--format', 'json', target],
      );
      final fileJsonLine = await fileJsonProc.stdout.next;
      check(fileJsonLine)
        ..contains('"declarations":')
        ..contains('"files":')
        ..contains('"violation":true');
      await fileJsonProc.shouldExit(1);

      // 3. --max-file-lines and --max-function-lines in github format
      final ghProc = await TestProcess.start(Platform.resolvedExecutable, [
        binPath,
        '--max-file-lines',
        '15',
        '--max-function-lines',
        '15',
        '--format',
        'github',
        target,
      ]);
      await check(ghProc.stdout).emitsThrough(
        (s) => s.contains('title=Declaration Line Limit Exceeded'),
      );
      await check(
        ghProc.stdout,
      ).emitsThrough((s) => s.contains('title=File Line Limit Exceeded'));
      await ghProc.shouldExit(1);
    });

    test(
      'Renders --git-diff text table with new/del transitions, '
      '[IMPROVED] only on improved functions, and omits 0-score items',
      () async {
        await d.dir('git_project', [
          d.dir('lib', [
            d.file('app.dart', '''
void zeroRemoved() {}

int deletedComplex(int a) {
  if (a > 0) {
    if (a > 1) return 2;
    return 1;
  }
  return 0;
}

int simplified(int a) {
  if (a > 0) {
    if (a > 1) return 2;
    return 1;
  }
  return 0;
}
'''),
          ]),
        ]).create();

        final repoDir = '${d.sandbox}/git_project';
        Future<void> git(List<String> args) async {
          final res = await Process.run('git', args, workingDirectory: repoDir);
          check(res.exitCode).equals(0);
        }

        await git(['init', '-b', 'main']);
        await git(['config', 'user.name', 'Tester']);
        await git(['config', 'user.email', 'test@example.com']);
        await git(['config', 'commit.gpgsign', 'false']);
        await git(['add', '.']);
        await git(['commit', '-m', 'Initial']);
        await git(['checkout', '-b', 'feature']);

        File('$repoDir/lib/app.dart').writeAsStringSync('''
void zeroAdded() {}

int addedComplex(int a) {
  if (a > 0) return 1;
  return 0;
}

int simplified(int a) {
  if (a > 0) return 1;
  return 0;
}
''');

        final proc = await TestProcess.start(
          Platform.resolvedExecutable,
          [binPath, '--git-diff', 'main'],
          workingDirectory: repoDir,
          // runCli re-aligns Directory.current to GITHUB_WORKSPACE when set.
          environment: {'GITHUB_WORKSPACE': repoDir},
        );

        final lines = <String>[];
        while (await proc.stdout.hasNext) {
          lines.add(await proc.stdout.next);
        }
        await proc.shouldExit(0);

        final output = lines.join('\n');
        check(output)
          ..contains('new -> 1')
          ..contains('addedComplex')
          ..contains('3 -> del')
          ..contains('deletedComplex  lib/app.dart')
          ..not((s) => s.contains('deletedComplex  lib/app.dart [IMPROVED]'))
          ..contains('3 -> 1')
          ..contains('simplified      lib/app.dart:L8-11 [IMPROVED]')
          ..not((s) => s.contains('zeroRemoved'))
          ..not((s) => s.contains('zeroAdded'))
          ..contains(
            'Summary: 1 added, 0 increased, 1 improved, 1 removed '
            '(Net Delta: -4 | Violations: 0)',
          );
      },
    );
  });
}
