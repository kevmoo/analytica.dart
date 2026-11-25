import 'dart:io';
import 'package:analytica/testing.dart';
import 'package:checks/checks.dart';
import 'package:cognitive_complexity/cognitive_complexity.dart';
import 'package:cognitive_complexity/src/complexity/cli.dart';
import 'package:cognitive_complexity/src/complexity/github_reporter.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;
import 'package:test_process/test_process.dart';

/// Builds a declaration whose cognitive complexity grows with [depth].
/// depth 1 scores 7 (below a threshold of 15), depth 3 scores 30 (above it).
String _decl(String name, int depth) {
  final buf = StringBuffer('int $name(int x) {\n');
  for (var i = 0; i < depth; i++) {
    final pad = '  ' * (i + 1);
    buf
      ..writeln('${pad}if (x > $i) {')
      ..writeln('$pad  for (var i = 0; i < x; i++) {')
      ..writeln('$pad    if (i % 2 == 0) x++; else x--;')
      ..writeln('$pad  }');
  }
  for (var i = depth - 1; i >= 0; i--) {
    buf.writeln('${'  ' * (i + 1)}}');
  }
  return (buf
        ..writeln('  return x;')
        ..writeln('}'))
      .toString();
}

Future<void> _runGit(String repoPath, List<String> args) async {
  final res = await Process.run('git', args, workingDirectory: repoPath);
  if (res.exitCode != 0) {
    fail('git ${args.join(" ")} failed:\n${res.stderr}');
  }
}

/// Creates a two-commit fixture repo at [repoPath]: six trivial declarations,
/// then f0..f2 become violations (score 30) while f3..f5 stay under the
/// threshold but still regress (score 7).
Future<void> _createFixtureRepo(String repoPath) async {
  await Directory(p.join(repoPath, 'lib')).create(recursive: true);

  await _runGit(repoPath, ['init', '-b', 'main']);
  await _runGit(repoPath, ['config', 'user.name', 'Tester']);
  await _runGit(repoPath, ['config', 'user.email', 'test@example.com']);
  await _runGit(repoPath, ['config', 'commit.gpgsign', 'false']);

  final src = p.join(repoPath, 'lib', 'a.dart');

  await File(src).writeAsString(
    [
      for (var i = 0; i < 6; i++) 'int f$i(int x) { return x + $i; }\n',
    ].join('\n'),
  );
  await _runGit(repoPath, ['add', '.']);
  await _runGit(repoPath, ['commit', '-m', 'base']);

  await File(src).writeAsString(
    [
      for (var i = 0; i < 3; i++) _decl('f$i', 3),
      for (var i = 3; i < 6; i++) _decl('f$i', 1),
    ].join('\n'),
  );
  await _runGit(repoPath, ['add', '.']);
  await _runGit(repoPath, ['commit', '-m', 'head']);
}

/// Counts markdown table rows (header rows included) in [report].
int _tableRowCount(String report) =>
    report.split('\n').where((l) => l.startsWith('| ')).length;

void main() {
  late String binPath;

  setUpAll(() async {
    binPath = await resolvePackageExecutable(
      'package:cognitive_complexity/cognitive_complexity.dart',
    );
  });

  group('--comment-output', () {
    late String repoPath;
    late String summaryPath;
    late String commentPath;

    /// Runs the scanner against the fixture repo to completion, returning
    /// its stdout. The fixture always contains violations, so a successful
    /// run exits 1; any other exit code (or a crash) fails the test with the
    /// process output attached.
    Future<String> runScanner(List<String> extraArgs) async {
      final process = await TestProcess.start(
        Platform.resolvedExecutable,
        [
          binPath,
          '--git-diff=HEAD~1',
          '--fail-threshold=15',
          '--fail-on-increase',
          '--format=github',
          ...extraArgs,
          'lib',
        ],
        workingDirectory: repoPath,
        // runCli re-aligns Directory.current to GITHUB_WORKSPACE when set.
        // On GitHub Actions that points at the (shallow) checkout, yanking
        // the scanner out of the fixture repo — pin it to the fixture.
        environment: {
          'GITHUB_STEP_SUMMARY': summaryPath,
          'GITHUB_WORKSPACE': repoPath,
        },
      );
      final out = (await process.stdoutStream().toList()).join('\n');
      await process.shouldExit(1);
      return out;
    }

    setUp(() async {
      repoPath = p.join(d.sandbox, 'repo');
      summaryPath = p.join(d.sandbox, 'summary.md');
      commentPath = p.join(d.sandbox, 'comment.md');
      await File(summaryPath).writeAsString('');
      await _createFixtureRepo(repoPath);
    });

    test('caps comment rows and keeps the full table in the step '
        'summary', () async {
      await runScanner([
        '--comment-output=$commentPath',
        '--max-comment-rows=2',
      ]);

      final comment = await File(commentPath).readAsString();
      final summary = await File(summaryPath).readAsString();

      // 2 header rows + 2 capped data rows.
      check(_tableRowCount(comment)).equals(4);
      // 2 header rows + all 6 changed declarations.
      check(_tableRowCount(summary)).equals(8);
      check(comment).contains('most significant of 6 changed declarations');
    });

    test('orders violations ahead of sub-threshold regressions', () async {
      await runScanner([
        '--comment-output=$commentPath',
        '--max-comment-rows=3',
      ]);

      final comment = await File(commentPath).readAsString();
      final shown = comment
          .split('\n')
          .where((l) => l.startsWith('| ') && l.contains('`f'))
          .toList();

      check(shown).length.equals(3);
      // Only the three violations may occupy a three-row budget.
      check(shown).every(.it()..contains('🔴'));
    });

    test('omits the truncation footer when everything fits', () async {
      await runScanner([
        '--comment-output=$commentPath',
        '--max-comment-rows=50',
      ]);

      final comment = await File(commentPath).readAsString();
      check(comment).not(.it()..contains('most significant of'));
    });

    test('annotates violations regardless of the cap', () async {
      final out = await runScanner([
        '--comment-output=$commentPath',
        '--max-comment-rows=1',
      ]);

      // Capping the comment must not hide inline Files-changed annotations.
      check('::error'.allMatches(out).length).equals(3);
      check('::warning'.allMatches(out).length).equals(0);
    });

    test('writes no comment file when --comment-output is omitted', () async {
      await runScanner([]);

      check(File(commentPath).existsSync()).isFalse;
      check(await File(summaryPath).readAsString()).contains('| 🔴 |');
    });

    test('writes no comment file when run is clean', () async {
      // An empty commit leaves HEAD identical to HEAD~1, so the diff is
      // resolvable but contains zero changed declarations.
      await _runGit(repoPath, ['commit', '--allow-empty', '-m', 'clean']);

      final process = await TestProcess.start(
        Platform.resolvedExecutable,
        [
          binPath,
          '--git-diff=HEAD~1', // But HEAD is now equal to HEAD~1
          '--fail-threshold=15',
          '--format=github',
          '--comment-output=$commentPath',
          'lib',
        ],
        workingDirectory: repoPath,
        environment: {
          'GITHUB_STEP_SUMMARY': summaryPath,
          'GITHUB_WORKSPACE': repoPath,
        },
      );
      await process.shouldExit(0);
      check(File(commentPath).existsSync()).isFalse;
    });

    test(
      'writes no comment file when the diff only improves complexity',
      () async {
        // Revert the violations, so HEAD~1 -> HEAD is a non-empty diff whose
        // every delta is an improvement. This distinguishes "0 violations and
        // 0 increases" from the weaker "nothing changed at all": a predicate
        // keyed on an empty delta list would wrongly post a comment here.
        await File(p.join(repoPath, 'lib', 'a.dart')).writeAsString(
          [
            for (var i = 0; i < 6; i++) 'int f$i(int x) { return x + $i; }\n',
          ].join('\n'),
        );
        await _runGit(repoPath, ['add', '.']);
        await _runGit(repoPath, ['commit', '-m', 'simplify']);

        final process = await TestProcess.start(
          Platform.resolvedExecutable,
          [
            binPath,
            '--git-diff=HEAD~1',
            '--fail-threshold=15',
            '--fail-on-increase',
            '--format=github',
            '--comment-output=$commentPath',
            'lib',
          ],
          workingDirectory: repoPath,
          environment: {
            'GITHUB_STEP_SUMMARY': summaryPath,
            'GITHUB_WORKSPACE': repoPath,
          },
        );
        await process.shouldExit(0);

        check(File(commentPath).existsSync()).isFalse;
        // The improvements are still reported, just not as an email.
        final summary = await File(summaryPath).readAsString();
        check(summary).contains('**Improved**: 6');
      },
    );

    test('--comment-on-clean writes comment file on clean and '
        'improvement-only diffs', () async {
      await File(p.join(repoPath, 'lib', 'a.dart')).writeAsString(
        [
          for (var i = 0; i < 6; i++) 'int f$i(int x) { return x + $i; }\n',
        ].join('\n'),
      );
      await _runGit(repoPath, ['add', '.']);
      await _runGit(repoPath, ['commit', '-m', 'simplify']);

      final deltaAnalyzer = DeltaAnalyzer(workingDirectory: repoPath);
      final deltaSummary = await deltaAnalyzer.computeDeltas(
        'HEAD~1',
        targetPaths: const ['lib'],
        failThreshold: 15,
        failOnIncrease: true,
      );

      final out = StringBuffer();
      GitHubReporter(
        stdoutSink: out,
        summaryFile: File(summaryPath),
        commentFile: File(commentPath),
        commentOnClean: true,
      ).printReport(
        deltaSummary: deltaSummary,
        failThreshold: 15,
        failOnIncrease: true,
      );

      check(File(commentPath).existsSync()).isTrue;
      final comment = await File(commentPath).readAsString();
      check(comment)
        ..contains('<!-- complexity-comment-marker -->')
        ..contains('**Improved**: 6');
    });
  });

  group('--comment-output in regular (full-scan) mode', () {
    test('skips comment when clean unless --comment-on-clean is set', () async {
      await d.dir('clean_full', [
        d.dir('lib', [
          d.file('ok.dart', 'int simple(int x) => x > 0 ? x : 0;\n'),
        ]),
      ]).create();

      final target = p.join(d.sandbox, 'clean_full', 'lib');
      final commentPath = p.join(d.sandbox, 'full_clean_comment.md');

      final out1 = StringBuffer();
      final err1 = StringBuffer();
      final rc1 = await runCli(
        [
          '--format=github',
          '--fail-threshold=15',
          '--comment-output=$commentPath',
          target,
        ],
        out: out1,
        err: err1,
      );
      check(rc1).equals(0);
      check(err1.toString()).isEmpty;
      check(File(commentPath).existsSync()).isFalse;

      final out2 = StringBuffer();
      final err2 = StringBuffer();
      final rc2 = await runCli(
        [
          '--format=github',
          '--fail-threshold=15',
          '--comment-output=$commentPath',
          '--comment-on-clean',
          target,
        ],
        out: out2,
        err: err2,
      );
      check(rc2).equals(0);
      check(err2.toString()).isEmpty;
      check(File(commentPath).existsSync()).isTrue;
      check(await File(commentPath).readAsString())
        ..contains('<!-- complexity-comment-marker -->')
        ..contains('`simple`');
    });

    test(
      'caps rows with violations first and emits annotations once',
      () async {
        final longBody = List.generate(
          20,
          (i) => '  final v$i = $i;',
        ).join('\n');
        await d.dir('vio_full', [
          d.dir('lib', [
            d.file('app.dart', '''
int cleanHigh(int x) {
  if (x > 0) {
    if (x > 1) return 2;
  }
  return 0;
}

void longZeroScore() {
$longBody
}

${_decl('tooComplex', 3)}
'''),
          ]),
        ]).create();

        final target = p.join(d.sandbox, 'vio_full', 'lib');
        final commentPath = p.join(d.sandbox, 'full_vio_comment.md');

        final out = StringBuffer();
        final err = StringBuffer();
        final rc = await runCli(
          [
            '--format=github',
            '--fail-threshold=15',
            '--max-function-lines=18',
            '--comment-output=$commentPath',
            '--max-comment-rows=2',
            target,
          ],
          out: out,
          err: err,
        );
        check(rc).equals(1);
        check(err.toString()).isEmpty;

        final comment = await File(commentPath).readAsString();
        // 2 header rows + 2 capped violation rows (`tooComplex` and
        // `longZeroScore`, ahead of non-violating `cleanHigh`).
        check(_tableRowCount(comment)).equals(4);
        check(comment)
          ..contains('`tooComplex`')
          ..contains('`longZeroScore`')
          ..not(.it()..contains('`cleanHigh`'))
          ..contains('Showing the 2 most significant of 3 declarations.');

        // Annotations must be emitted once per violation, not duplicated for
        // the comment buffer.
        check('::error'.allMatches(out.toString()).length).equals(2);
      },
    );

    test(
      'warns when --comment-on-clean is used without --comment-output',
      () async {
        await d.dir('warn_clean', [
          d.dir('lib', [d.file('a.dart', 'int a() => 1;\n')]),
        ]).create();

        final out = StringBuffer();
        final err = StringBuffer();
        final rc = await runCli(
          [
            '--format=github',
            '--comment-on-clean',
            p.join(d.sandbox, 'warn_clean', 'lib'),
          ],
          out: out,
          err: err,
        );
        check(rc).equals(0);
        check(err.toString()).contains(
          '--comment-on-clean has no effect unless --comment-output is set.',
        );
      },
    );
  });
}
