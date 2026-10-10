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

    test('--verbose adds a Breakdown column and tags test entrypoints; '
        'JSON always carries composition', () async {
      await d.dir('project_verbose', [
        d.dir('lib', [
          d.file('shape.dart', '''
int pyramid(bool a, bool b, bool c) {
  if (a) {
    if (b) {
      if (c) {
        return 3;
      }
    }
  }
  return 0;
}
'''),
        ]),
        d.dir('test', [
          d.file('shape_test.dart', '''
void main() {
  group('g', () {
    test('t', () {
      if (a && b) {}
    });
  });
}
'''),
        ]),
      ]).create();

      final text = await TestProcess.start(Platform.resolvedExecutable, [
        binPath,
        '--verbose',
        '${d.sandbox}/project_verbose/lib',
        '${d.sandbox}/project_verbose/test',
      ]);
      await check(
        text.stdout,
      ).emitsThrough((s) => s.contains('Score  Breakdown'));
      await check(text.stdout).emitsThrough(
        (s) => s
          ..contains('6  br 3 nest 3 bool 0 depth 3  pyramid')
          ..not((s) => s.contains('[test entrypoint]')),
      );
      await check(text.stdout).emitsThrough(
        (s) => s
          ..contains('4  br 1 nest 2 bool 1 depth 3  main')
          ..endsWith('[test entrypoint]'),
      );
      await text.shouldExit(0);

      final plain = await TestProcess.start(Platform.resolvedExecutable, [
        binPath,
        '${d.sandbox}/project_verbose/test',
      ]);
      await check(plain.stdout).emitsThrough(
        (s) => s
          ..contains('4  main')
          ..not((s) => s.contains('br '))
          ..not((s) => s.contains('[test entrypoint]')),
      );
      await plain.shouldExit(0);

      final json = await TestProcess.start(Platform.resolvedExecutable, [
        binPath,
        '--format',
        'json',
        '--verbose',
        '${d.sandbox}/project_verbose/test',
      ]);
      await check(json.stderr).emitsThrough(
        (s) => s.contains(
          '--verbose only affects --format=text without --git-diff',
        ),
      );
      await check(json.stdout).emitsThrough(
        (s) => s
          ..contains(
            '"composition":{"branches":1,"nesting":2,"boolean_ops":1,'
            '"max_depth":3}',
          )
          ..contains('"is_test_entrypoint":true'),
      );
      await json.shouldExit(0);
    });

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
      ).emitsThrough((s) => s.contains('[VIOLATION: score > 2]'));
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
        ..contains('"schema_version":1')
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

      // 4. --max-function-lines in text format emits Lines and violations
      final textProc = await TestProcess.start(Platform.resolvedExecutable, [
        binPath,
        '--max-file-lines',
        '15',
        '--max-function-lines',
        '15',
        '--format',
        'text',
        target,
      ]);
      final textLines = await textProc.stdoutStream().join('\n');
      check(textLines)
        ..contains('Score  Lines  Declaration  Location')
        ..contains('    0     27  bigDecl      ')
        ..contains('[VIOLATION: lines > 15]');
      await textProc.shouldExit(1);
    });

    group('default target discovery (no positional args)', () {
      const complexFn = '''
int compute(int x) {
  if (x > 0) {
    if (x > 10) {
      return 2;
    }
    return 1;
  }
  return 0;
}
''';

      Future<String> runJson(String cwd) async {
        final proc = await TestProcess.start(
          Platform.resolvedExecutable,
          [binPath, '--format', 'json'],
          workingDirectory: cwd,
          // runCli re-aligns Directory.current to GITHUB_WORKSPACE when set.
          environment: {'GITHUB_WORKSPACE': cwd},
        );
        final lines = <String>[];
        while (await proc.stdout.hasNext) {
          lines.add(await proc.stdout.next);
        }
        await proc.shouldExit(0);
        return lines.join('\n');
      }

      test('workspace root scans every member lib/', () async {
        await d.dir('ws', [
          d.file('pubspec.yaml', '''
name: ws
workspace:
  - pkg_a
  - pkg_b
'''),
          d.dir('pkg_a', [
            d.file('pubspec.yaml', 'name: pkg_a\n'),
            d.dir('lib', [d.file('a.dart', complexFn)]),
            d.dir('test', [d.file('a_test.dart', complexFn)]),
          ]),
          d.dir('pkg_b', [
            d.file('pubspec.yaml', 'name: pkg_b\n'),
            d.dir('lib', [d.file('b.dart', complexFn)]),
          ]),
        ]).create();

        final output = await runJson('${d.sandbox}/ws');
        check(output)
          ..contains('pkg_a/lib/a.dart')
          ..contains('pkg_b/lib/b.dart')
          ..not((s) => s.contains('pkg_a/test/a_test.dart'));
      });

      test('packages/* monorepo scans lib/ but not test/', () async {
        await d.dir('mono', [
          d.dir('packages', [
            d.dir('one', [
              d.file('pubspec.yaml', 'name: one\n'),
              d.dir('lib', [d.file('one.dart', complexFn)]),
              d.dir('test', [d.file('one_test.dart', complexFn)]),
            ]),
          ]),
        ]).create();

        final output = await runJson('${d.sandbox}/mono');
        check(output)
          ..contains('packages/one/lib/one.dart')
          ..not((s) => s.contains('one_test.dart'));
      });

      test('explicit targets override discovery verbatim', () async {
        await d.dir('explicit', [
          d.file('pubspec.yaml', '''
name: ws
workspace:
  - pkg_a
'''),
          d.dir('pkg_a', [
            d.file('pubspec.yaml', 'name: pkg_a\n'),
            d.dir('lib', [d.file('a.dart', complexFn)]),
            d.dir('test', [d.file('a_test.dart', complexFn)]),
          ]),
        ]).create();

        final proc = await TestProcess.start(
          Platform.resolvedExecutable,
          [binPath, '--format', 'json', 'pkg_a/test'],
          workingDirectory: '${d.sandbox}/explicit',
          environment: {'GITHUB_WORKSPACE': '${d.sandbox}/explicit'},
        );
        final lines = <String>[];
        while (await proc.stdout.hasNext) {
          lines.add(await proc.stdout.next);
        }
        await proc.shouldExit(0);
        check(lines.join('\n'))
          ..contains('pkg_a/test/a_test.dart')
          ..not((s) => s.contains('pkg_a/lib/a.dart'));
      });
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

    test('orders --git-diff text rows by significance (violations first, '
        'then new score desc) and renders Lines + violation reasons', () async {
      // Sequential top-level `if`s give an exact CC of [cc]; [filler]
      // pads the declaration's physical line count without adding CC.
      String fn(String name, int cc, {int filler = 0}) {
        final body = [
          for (var i = 0; i < filler; i++) '  final x$i = $i;',
          for (var i = 0; i < cc; i++) '  if (a > $i) return $i;',
          '  return -1;',
        ].join('\n');
        return 'int $name(int a) {\n$body\n}\n';
      }

      await d.dir('git_sort', [
        d.dir('lib', [
          d.file(
            'app.dart',
            [
              fn('violator', 1),
              fn('grownButOk', 1),
              fn('improved', 6),
              fn('deletedComplex', 2),
            ].join('\n'),
          ),
        ]),
      ]).create();

      final repoDir = '${d.sandbox}/git_sort';
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

      // violator:   1 -> 4   score violation (> 3)
      // grownButOk: 1 -> 3   increased but within threshold
      // brandNew:   new -> 2 lines-only violation (13 lines > 8)
      // improved:   6 -> 5   improved; new score is HIGHER than violator's
      // deletedComplex: 2 -> del
      File('$repoDir/lib/app.dart').writeAsStringSync(
        [
          fn('violator', 4),
          fn('grownButOk', 3),
          fn('brandNew', 2, filler: 8),
          fn('improved', 5),
        ].join('\n'),
      );

      final proc = await TestProcess.start(
        Platform.resolvedExecutable,
        [
          binPath,
          '--git-diff',
          'main',
          '--fail-threshold',
          '3',
          '--max-function-lines',
          '8',
        ],
        workingDirectory: repoDir,
        environment: {'GITHUB_WORKSPACE': repoDir},
      );

      final lines = <String>[];
      while (await proc.stdout.hasNext) {
        lines.add(await proc.stdout.next);
      }
      await proc.shouldExit(1);

      // Table rows are the only lines that start with a padded delta.
      final rows = lines
          .where((l) => RegExp(r'^\s*[+-]?\d+\s{2}').hasMatch(l))
          .toList();
      final nameOf = RegExp(
        r'\b(violator|grownButOk|brandNew|improved|deletedComplex)\b',
      );
      check(
        rows.map((r) => nameOf.firstMatch(r)!.group(1)).toList(),
      ).deepEquals([
        'violator', // violation (score), new score 4
        'brandNew', // violation (lines) despite new score 2
        'improved', // non-violation, new score 5
        'grownButOk', // non-violation, new score 3
        'deletedComplex', // non-violation, new score 0
      ]);

      check(lines.join('\n')).contains(
        ' Delta  Score         Lines         Declaration     Location',
      );
      check(rows[0])
        ..contains('1 -> 4')
        ..endsWith('[VIOLATION: score > 3]');
      check(rows[1])
        ..contains('new -> 2')
        ..contains('new -> 13')
        ..endsWith('[VIOLATION: lines > 8]');
      check(rows[2])
        ..contains('6 -> 5')
        ..endsWith('[IMPROVED]');
      check(rows[3])
        ..contains('1 -> 3')
        ..not((r) => r.contains('['));
      check(rows[4])
        ..contains('2 -> del')
        ..not((r) => r.contains('['));
    });
  });
}
