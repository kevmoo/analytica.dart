import 'dart:convert';
import 'dart:io';

import 'package:analytica/testing.dart';
import 'package:checks/checks.dart';
import 'package:cognitive_complexity/src/complexity/cli.dart';
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
      ).emitsThrough(.it()..contains('Score  Declaration'));
      await check(process.stdout).emitsThrough(.it()..contains('3  compute'));
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
          .it()
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
      ).emitsThrough(.it()..contains('Score  Breakdown'));
      await check(text.stdout).emitsThrough(
        .it()
          ..contains('6  br 3 nest 3 bool 0 depth 3  pyramid')
          ..not(.it()..contains('[test entrypoint]')),
      );
      await check(text.stdout).emitsThrough(
        .it()
          ..contains('4  br 1 nest 2 bool 1 depth 3  main')
          ..endsWith('[test entrypoint]'),
      );
      await text.shouldExit(0);

      final plain = await TestProcess.start(Platform.resolvedExecutable, [
        binPath,
        '${d.sandbox}/project_verbose/test',
      ]);
      await check(plain.stdout).emitsThrough(
        .it()
          ..contains('4  main')
          ..not(.it()..contains('br '))
          ..not(.it()..contains('[test entrypoint]')),
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
        .it()
          ..contains('--verbose only affects --format=text without --git-diff'),
      );
      await check(json.stdout).emitsThrough(
        .it()
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
      ).emitsThrough(.it()..contains('[VIOLATION: score > 2]'));
      await check(
        process.stderr,
      ).emitsThrough(.it()..contains('exceeded the failure threshold (2)'));
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
      check(defaultJsonLine.startsWith('[')).isTrue;
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
      await check(
        ghProc.stdout,
      ).emitsThrough(.it()..contains('title=Declaration Line Limit Exceeded'));
      await check(
        ghProc.stdout,
      ).emitsThrough(.it()..contains('title=File Line Limit Exceeded'));
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
          ..not(.it()..contains('pkg_a/test/a_test.dart'));
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
          ..not(.it()..contains('one_test.dart'));
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
          ..not(.it()..contains('pkg_a/lib/a.dart'));
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
          ..not(.it()..contains('deletedComplex  lib/app.dart [IMPROVED]'))
          ..contains('3 -> 1')
          ..contains('simplified      lib/app.dart:L8-11 [IMPROVED]')
          ..not(.it()..contains('zeroRemoved'))
          ..not(.it()..contains('zeroAdded'))
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
        ..not(.it()..contains('['));
      check(rows[4])
        ..contains('2 -> del')
        ..not(.it()..contains('['));
    });

    test('Reports suppressed declarations in text, json, and --git-diff '
        'modes without counting them as threshold violations', () async {
      await d.dir('suppressed_project', [
        d.dir('lib', [
          d.file('app.dart', '''
int cleanFunc(int a) {
  if (a > 0) return 1;
  return 0;
}

// cognitive_complexity:ignore -- generated parser table
int suppressedWithReason(int a) {
  if (a > 0) {
    if (a > 1) {
      if (a > 2) return 3;
    }
  }
  return 0;
}

// cognitive_complexity:ignore
int suppressedNoReason(int a) {
  if (a > 0) {
    if (a > 1) return 2;
  }
  return 0;
}
'''),
        ]),
      ]).create();

      final repoDir = '${d.sandbox}/suppressed_project';

      // 1. Standard CLI text mode: exits 0 even though suppressed functions
      // exceed --fail-threshold 2, and prints Suppressed declarations (2):
      final textProc = await TestProcess.start(Platform.resolvedExecutable, [
        binPath,
        '--fail-threshold',
        '2',
        repoDir,
      ]);
      final textOut = await textProc.stdoutStream().join('\n');
      await textProc.shouldExit(0);
      check(textOut)
        ..contains('Suppressed declarations (2):')
        ..contains(
          'suppressedWithReason (score: 6, reason: generated parser table)',
        )
        ..contains('suppressedNoReason (score: 3, no reason)');

      // 2. --format=json mode: includes suppressedDeclarations on file entries,
      // top-level, and summary counts while keeping declarations clean
      final jsonProc = await TestProcess.start(Platform.resolvedExecutable, [
        binPath,
        '--format',
        'json',
        repoDir,
      ]);
      final jsonOut = await jsonProc.stdoutStream().join('\n');
      await jsonProc.shouldExit(0);
      check(jsonOut)
        ..contains('"suppressedDeclarations":2')
        ..contains('"name":"suppressedWithReason"')
        ..contains('"score":6')
        ..contains('"reason":"generated parser table"')
        ..contains('"name":"suppressedNoReason"')
        ..contains('"reason":null');

      // 3. --git-diff mode: surfaces newly added or modified suppressions
      Future<void> git(List<String> args) async {
        final res = await Process.run('git', args, workingDirectory: repoDir);
        check(res.exitCode).equals(0);
      }

      await git(['init', '-b', 'main']);
      await git(['config', 'user.name', 'Tester']);
      await git(['config', 'user.email', 'test@example.com']);
      await git(['config', 'commit.gpgsign', 'false']);
      File('$repoDir/lib/app.dart').writeAsStringSync('''
int cleanFunc(int a) {
  if (a > 0) return 1;
  return 0;
}
''');
      await git(['add', '.']);
      await git(['commit', '-m', 'Initial without suppressions']);

      File('$repoDir/lib/app.dart').writeAsStringSync('''
int cleanFunc(int a) {
  if (a > 0) return 1;
  return 0;
}

// cognitive_complexity:ignore: protocol compatibility
int newlySuppressed(int a) {
  if (a > 0) {
    if (a > 1) {
      if (a > 2) return 3;
    }
  }
  return 0;
}
''');

      final diffTextProc = await TestProcess.start(
        Platform.resolvedExecutable,
        [binPath, '--git-diff', 'main', '--fail-threshold', '2'],
        workingDirectory: repoDir,
        environment: {'GITHUB_WORKSPACE': repoDir},
      );
      final diffTextOut = await diffTextProc.stdoutStream().join('\n');
      await diffTextProc.shouldExit(0);
      check(diffTextOut)
        ..contains('Suppressed declarations (1):')
        ..contains(
          'newlySuppressed (score: 6, reason: protocol compatibility)',
        );

      final diffJsonProc = await TestProcess.start(
        Platform.resolvedExecutable,
        [binPath, '--git-diff', 'main', '--format', 'json'],
        workingDirectory: repoDir,
        environment: {'GITHUB_WORKSPACE': repoDir},
      );
      final diffJsonOut = await diffJsonProc.stdoutStream().join('\n');
      await diffJsonProc.shouldExit(0);
      check(diffJsonOut)
        ..contains('"suppressedDeclarations":1')
        ..contains('"name":"newlySuppressed"')
        ..contains('"reason":"protocol compatibility"');
    });

    group('stdin target (-)', () {
      Future<({String stdout, String stderr, int exitCode})> runWithStdin(
        List<String> args,
        String input,
      ) async {
        final out = StringBuffer();
        final err = StringBuffer();
        final code = await runCli(
          args,
          out: out,
          err: err,
          input: Stream<List<int>>.value(utf8.encode(input)),
        );
        return (stdout: out.toString(), stderr: err.toString(), exitCode: code);
      }

      test('pipes real process stdin end-to-end', () async {
        final proc = await TestProcess.start(Platform.resolvedExecutable, [
          binPath,
          '-',
        ]);
        proc.stdin.writeln('int f(int x) => x > 0 ? x : -x;');
        await proc.stdin.close();

        await check(
          proc.stdout,
        ).emitsThrough(.it()..contains('1  f            <stdin>:L1-1'));
        await proc.shouldExit(0);
      });

      test('scores Dart snippet from stdin in text and JSON formats', () async {
        const snippet = '''
int f(int x) {
  if (x > 0) {
    if (x > 10) return 2;
    return 1;
  }
  return 0;
}
''';

        final text = await runWithStdin(['-'], snippet);
        check(text.exitCode).equals(0);
        check(text.stdout)
          ..contains('Score  Declaration')
          ..contains('    3  f            <stdin>:L1-7');

        final json = await runWithStdin(['--format', 'json', '-'], snippet);
        check(json.exitCode).equals(0);
        check(json.stdout)
          ..contains('"file":"<stdin>"')
          ..contains('"name":"f"')
          ..contains('"score":3');
      });

      test('enforces --fail-threshold, --max-file-lines, and '
          '--max-function-lines on stdin', () async {
        const snippet = '''
int f(int x) {
  if (x > 0) {
    if (x > 10) return 2;
    return 1;
  }
  return 0;
}
''';

        final threshold = await runWithStdin([
          '--fail-threshold',
          '2',
          '-',
        ], snippet);
        check(threshold.exitCode).equals(1);
        check(threshold.stdout).contains('[VIOLATION: score > 2]');

        final fileLines = await runWithStdin([
          '--max-file-lines',
          '4',
          '--max-function-lines',
          '4',
          '--format',
          'json',
          '-',
        ], snippet);
        check(fileLines.exitCode).equals(1);
        check(fileLines.stdout)
          ..contains('"file":"<stdin>"')
          ..contains('"lines":8')
          ..contains('"violation":true');
      });

      test('respects ignore directives and handles empty stdin', () async {
        const suppressedSnippet = '''
// cognitive_complexity:ignore -- lookup table
int ignored(int x) {
  if (x > 0) {
    if (x > 1) return 2;
  }
  return 0;
}
''';
        final suppressed = await runWithStdin([
          '--fail-threshold',
          '1',
          '-',
        ], suppressedSnippet);
        check(suppressed.exitCode).equals(0);
        check(suppressed.stdout)
          ..contains('Suppressed declarations (1):')
          ..contains('ignored (score: 3, reason: lookup table)  <stdin>:L2-7');

        const ignoreForFile = '''
// cognitive_complexity:ignore_for_file
int skipped(int x) {
  if (x > 0) {
    if (x > 1) return 2;
  }
  return 0;
}
''';
        final skipped = await runWithStdin([
          '--fail-threshold',
          '1',
          '--max-file-lines',
          '2',
          '-',
        ], ignoreForFile);
        check(skipped.exitCode).equals(0);
        check(skipped.stdout).contains('No Dart declarations analyzed.');

        final empty = await runWithStdin(['--max-file-lines', '10', '-'], '');
        check(empty.exitCode).equals(0);
        check(empty.stdout).contains('No Dart declarations analyzed.');
      });

      test('mixes stdin target with file targets', () async {
        await d.dir('stdin_mix', [
          d.file('other.dart', 'int g(int x) => x > 0 ? 1 : 0;\n'),
        ]).create();

        final result = await runWithStdin([
          '-',
          '${d.sandbox}/stdin_mix/other.dart',
        ], 'int f(int x) { if (x > 0) { if (x > 1) return 2; } return 0; }\n');
        check(result.exitCode).equals(0);
        check(result.stdout)
          ..contains('<stdin>:L1-1')
          ..contains('other.dart:L1-1');
      });

      test('rejects - combined with --git-diff with exit code 64', () async {
        final result = await runWithStdin([
          '--git-diff',
          'HEAD',
          '-',
        ], 'int f(int x) => x;\n');
        check(result.exitCode).equals(64);
        check(
          result.stderr,
        ).contains('Cannot combine stdin target "-" with --git-diff.');
      });

      test('rejects duplicate - targets with exit code 64', () async {
        final result = await runWithStdin(['-', '-'], 'int f(int x) => x;\n');
        check(result.exitCode).equals(64);
        check(
          result.stderr,
        ).contains('Stdin target "-" cannot be specified more than once.');
      });
    });
  });
}
