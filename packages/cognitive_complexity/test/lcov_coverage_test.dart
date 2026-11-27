import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:cognitive_complexity/cognitive_complexity.dart';
import 'package:cognitive_complexity/src/complexity/cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

void main() {
  group('DeclarationCoverage', () {
    test('computes percent, short format, and JSON for loaded coverage', () {
      const cov = DeclarationCoverage(
        loaded: true,
        coveredLines: 5,
        executableLines: 12,
        uncoveredLines: [48, 49, 50, 52, 61, 62],
      );

      check(cov.percent).equals(41.7);
      check(cov.formatShort()).equals('42% (5/12)');
      check(cov.formatUncoveredRanges()).equals('L48-50, L52, L61-62');
      check(cov.toJson()).deepEquals({
        'loaded': true,
        'covered_lines': 5,
        'executable_lines': 12,
        'percent': 41.7,
        'uncovered_lines': [48, 49, 50, 52, 61, 62],
      });
    });

    test('treats unloaded file as 0.0% coverage', () {
      const cov = DeclarationCoverage(
        loaded: false,
        coveredLines: 0,
        executableLines: 0,
        uncoveredLines: [],
      );

      check(cov.percent).equals(0.0);
      check(cov.formatShort()).equals('0% (unloaded)');
      check(cov.formatUncoveredRanges()).isEmpty;
    });

    test('returns null percent and n/a when loaded file has 0 executable lines '
        'in declaration', () {
      const cov = DeclarationCoverage(
        loaded: true,
        coveredLines: 0,
        executableLines: 0,
        uncoveredLines: [],
      );

      check(cov.percent).isNull;
      check(cov.formatShort()).equals('n/a');
    });

    test(
      'caps formatUncoveredRanges when disjoint ranges exceed maxRanges',
      () {
        const cov = DeclarationCoverage(
          loaded: true,
          coveredLines: 1,
          executableLines: 8,
          uncoveredLines: [2, 4, 6, 8, 10, 12, 13],
        );

        check(
          cov.formatUncoveredRanges(maxRanges: 3),
        ).equals('L2, L4, L6, +3 more');
        check(
          cov.formatUncoveredRanges(maxRanges: 0),
        ).equals('L2, L4, L6, L8, L10, L12-13');
      },
    );
  });

  group('LcovCoverage.parse', () {
    test('parses SF/DA records, checksums, and merges duplicate SF blocks', () {
      const lcov = '''
TN:suite_1
SF:lib/a.dart
FN:1,foo
FNDA:1,foo
DA:2,1
DA:3,0,deadbeef
DA:4,0
BRDA:3,0,0,1
LF:3
LH:1
end_of_record
SF:lib/a.dart
DA:3,2
DA:5,0
end_of_record
''';
      final coverage = LcovCoverage.parse(lcov, baseDirectory: '/repo');
      check(coverage.fileCount).equals(1);

      final cov = coverage.coverageFor(
        filePath: 'lib/a.dart',
        startLine: 1,
        endLine: 6,
      );
      check(cov.loaded).isTrue;
      check(cov.executableLines).equals(4);
      check(cov.coveredLines).equals(2);
      check(cov.uncoveredLines).deepEquals([4, 5]);
      check(cov.percent).equals(50.0);

      final unloaded = coverage.coverageFor(
        filePath: 'lib/missing.dart',
        startLine: 1,
        endLine: 10,
      );
      check(unloaded.loaded).isFalse;
      check(unloaded.percent).equals(0.0);
    });

    test(
      'normalizes Windows backslashes and resolves package fallback dir',
      () async {
        await d.dir('pkg', [
          d.dir('lib', [d.file('sample.dart', 'void f() {}\n')]),
          d.dir('coverage', [
            d.file('lcov.info', r'''
SF:lib\sample.dart
DA:1,3
end_of_record
'''),
          ]),
        ]).create();

        final pkgDir = p.join(d.sandbox, 'pkg');
        final lcovPath = p.join(pkgDir, 'coverage', 'lcov.info');
        final samplePath = p.join(pkgDir, 'lib', 'sample.dart');

        // Base dir is the sandbox root (simulating a workspace run), while
        // SF:lib\sample.dart is relative to pkg/.
        final coverage = LcovCoverage.fromFile(
          lcovPath,
          baseDirectory: d.sandbox,
        );
        final cov = coverage.coverageFor(
          filePath: samplePath,
          startLine: 1,
          endLine: 1,
        );
        check(cov.loaded).isTrue;
        check(cov.coveredLines).equals(1);
        check(cov.executableLines).equals(1);
      },
    );

    test('fromFile throws FormatException on directory and FileSystemException '
        'when missing', () async {
      await d.dir('cov_dir').create();

      check(
          () => LcovCoverage.fromFile(p.join(d.sandbox, 'cov_dir')),
        ).throws<FormatException>().has('message', (e) => e.message)
        ..contains('--coverage-path=coverage/lcov.info')
        ..contains('flutter test --coverage');

      check(
        () => LcovCoverage.fromFile(p.join(d.sandbox, 'nope.info')),
      ).throws<FileSystemException>();
    });
  });

  group('CLI --coverage integration', () {
    test(
      'annotates text, json, and github regular reports with coverage',
      () async {
        await d.dir('proj', [
          d.dir('lib', [
            d.file('covered.dart', '''
int classify(int x) {
  if (x > 0) {
    return 1;
  } else if (x < 0) {
    return -1;
  }
  return 0;
}
'''),
            d.file('unloaded.dart', '''
int untested(int x) {
  if (x > 0) {
    return x;
  }
  return 0;
}
'''),
          ]),
          d.dir('coverage', [
            d.file('lcov.info', '''
SF:lib/covered.dart
DA:1,1
DA:2,1
DA:3,1
DA:4,0
DA:5,0
DA:7,0
end_of_record
'''),
          ]),
        ]).create();

        final projDir = p.join(d.sandbox, 'proj');
        final lcovPath = p.join(projDir, 'coverage', 'lcov.info');
        final libDir = p.join(projDir, 'lib');

        // 1. Text format
        final textOut = StringBuffer();
        final textErr = StringBuffer();
        final textCode = await runCli(
          ['--coverage=$lcovPath', libDir],
          out: textOut,
          err: textErr,
        );
        check(textCode).equals(0);
        check(textErr.toString()).isEmpty;
        check(textOut.toString())
          ..contains('Coverage')
          ..contains('50% (3/6)')
          ..contains('[uncovered: L4-5, L7]')
          ..contains('0% (unloaded)');

        // 2. JSON format (with --coverage)
        final jsonOut = StringBuffer();
        final jsonCode = await runCli(
          ['--format=json', '--coverage=$lcovPath', libDir],
          out: jsonOut,
          err: StringBuffer(),
        );
        check(jsonCode).equals(0);
        final decoded = jsonDecode(jsonOut.toString()) as List<dynamic>;
        final byName = {
          for (final item in decoded.cast<Map<String, dynamic>>())
            item['name'] as String: item,
        };
        check(
          byName['classify']!['coverage'],
        ).isA<Map<String, dynamic>>().deepEquals({
          'loaded': true,
          'covered_lines': 3,
          'executable_lines': 6,
          'percent': 50.0,
          'uncovered_lines': [4, 5, 7],
        });
        check(
          byName['untested']!['coverage'],
        ).isA<Map<String, dynamic>>().deepEquals({
          'loaded': false,
          'covered_lines': 0,
          'executable_lines': 0,
          'percent': 0.0,
          'uncovered_lines': <int>[],
        });

        // 3. JSON format without --coverage omits the coverage key
        final baselineOut = StringBuffer();
        final baselineCode = await runCli(
          ['--format=json', libDir],
          out: baselineOut,
          err: StringBuffer(),
        );
        check(baselineCode).equals(0);
        final baselineList =
            jsonDecode(baselineOut.toString()) as List<dynamic>;
        for (final item in baselineList.cast<Map<String, dynamic>>()) {
          check(item.containsKey('coverage')).isFalse;
        }

        // 4. GitHub format (summary + comment-output)
        final summaryPath = p.join(d.sandbox, 'summary.md');
        final commentPath = p.join(d.sandbox, 'comment.md');
        final ghCode = await runCli(
          [
            '--format=github',
            '--coverage=$lcovPath',
            '--comment-output=$commentPath',
            '--comment-on-clean',
            libDir,
          ],
          out: StringBuffer(),
          err: StringBuffer(),
          environment: {'GITHUB_STEP_SUMMARY': summaryPath},
        );
        check(ghCode).equals(0);
        for (final path in [summaryPath, commentPath]) {
          check(File(path).readAsStringSync())
            ..contains('| Status | Declaration | Location | Score | Coverage |')
            ..contains('| 50% (3/6) |')
            ..contains('| 0% (unloaded) |');
        }
      },
    );

    test(
      'annotates --git-diff reports across text, json, and github formats',
      () async {
        await d.dir('git_proj', [
          d.dir('lib', [
            d.file('work.dart', '''
int keep(int x) {
  if (x > 0) return 1;
  return 0;
}

int toRemove(int x) {
  if (x > 0) return 1;
  return 0;
}
'''),
          ]),
        ]).create();

        final repoDir = p.join(d.sandbox, 'git_proj');
        Future<void> git(List<String> args) async {
          final res = await Process.run('git', args, workingDirectory: repoDir);
          if (res.exitCode != 0) {
            fail('git ${args.join(' ')} failed: ${res.stderr}');
          }
        }

        await git(['init', '-b', 'main']);
        await git(['config', 'user.email', 'test@example.com']);
        await git(['config', 'user.name', 'Test']);
        await git(['add', '.']);
        await git(['commit', '-m', 'init']);

        // Modify keep (increase CC), add brandNew (unloaded), remove toRemove.
        await File(p.join(repoDir, 'lib', 'work.dart')).writeAsString('''
int keep(int x) {
  if (x > 0) {
    if (x > 10) return 2;
    return 1;
  }
  return 0;
}
''');
        await File(p.join(repoDir, 'lib', 'fresh.dart')).writeAsString('''
int brandNew(int x) {
  if (x > 0) return 1;
  return 0;
}
''');
        await git(['add', 'lib/fresh.dart']);
        final lcovPath = p.join(repoDir, 'coverage', 'lcov.info');
        await File(lcovPath).parent.create(recursive: true);
        await File(lcovPath).writeAsString('''
SF:lib/work.dart
DA:2,1
DA:3,0
DA:4,1
DA:6,0
end_of_record
''');

        final prevCwd = Directory.current;
        try {
          Directory.current = repoDir;

          // Text
          final textOut = StringBuffer();
          final textCode = await runCli(
            ['--git-diff=HEAD', '--coverage=$lcovPath', 'lib'],
            out: textOut,
            err: StringBuffer(),
          );
          check(textCode).equals(0);
          check(textOut.toString())
            ..contains('Coverage')
            ..contains('50% (2/4)')
            ..contains('[uncovered: L3, L6]')
            ..contains('0% (unloaded)')
            ..contains('—');

          // JSON
          final jsonOut = StringBuffer();
          final jsonCode = await runCli(
            ['--git-diff=HEAD', '--format=json', '--coverage=$lcovPath', 'lib'],
            out: jsonOut,
            err: StringBuffer(),
          );
          check(jsonCode).equals(0);
          final decoded =
              jsonDecode(jsonOut.toString()) as Map<String, dynamic>;
          final deltas = {
            for (final item
                in (decoded['deltas'] as List).cast<Map<String, dynamic>>())
              item['name'] as String: item,
          };
          check(
            deltas['keep']!['coverage'],
          ).isA<Map<String, dynamic>>().deepEquals({
            'loaded': true,
            'covered_lines': 2,
            'executable_lines': 4,
            'percent': 50.0,
            'uncovered_lines': [3, 6],
          });
          check(
            deltas['brandNew']!['coverage'],
          ).isA<Map<String, dynamic>>().deepEquals({
            'loaded': false,
            'covered_lines': 0,
            'executable_lines': 0,
            'percent': 0.0,
            'uncovered_lines': <int>[],
          });
          check(deltas['toRemove']!.containsKey('coverage')).isFalse;

          // GitHub
          final summaryPath = p.join(d.sandbox, 'diff_summary.md');
          final ghCode = await runCli(
            [
              '--git-diff=HEAD',
              '--format=github',
              '--coverage=$lcovPath',
              'lib',
            ],
            out: StringBuffer(),
            err: StringBuffer(),
            environment: {'GITHUB_STEP_SUMMARY': summaryPath},
          );
          check(ghCode).equals(0);
          check(File(summaryPath).readAsStringSync())
            ..contains(
              '| Status | Declaration | Location | Delta | Score | Coverage |',
            )
            ..contains('| 50% (2/4) |')
            ..contains('| 0% (unloaded) |')
            ..contains('| — |');
        } finally {
          Directory.current = prevCwd;
        }
      },
    );

    test(
      'validates empty, directory, missing, and stdin --coverage flags',
      () async {
        await d.dir('bad_cov').create();
        await d.file('empty.info', '').create();

        // Empty value
        final errEmpty = StringBuffer();
        check(
          await runCli(
            ['--coverage=', '-'],
            out: StringBuffer(),
            err: errEmpty,
            input: Stream.value(utf8.encode('void f() {}')),
          ),
        ).equals(64);
        check(
          errEmpty.toString(),
        ).contains('Coverage file path cannot be empty');

        // Directory passed to --coverage
        final errDir = StringBuffer();
        check(
          await runCli(
            ['--coverage=${p.join(d.sandbox, 'bad_cov')}', '-'],
            out: StringBuffer(),
            err: errDir,
            input: Stream.value(utf8.encode('void f() {}')),
          ),
        ).equals(64);
        check(errDir.toString()).contains('--coverage-path=coverage/lcov.info');

        // Missing file
        final errMissing = StringBuffer();
        check(
          await runCli(
            ['--coverage=${p.join(d.sandbox, 'missing.info')}', '-'],
            out: StringBuffer(),
            err: errMissing,
            input: Stream.value(utf8.encode('void f() {}')),
          ),
        ).equals(64);
        check(errMissing.toString()).contains('Coverage file does not exist');

        // Valid lcov + stdin target emits warning and omits coverage on <stdin>
        final stdinOut = StringBuffer();
        final stdinErr = StringBuffer();
        check(
          await runCli(
            [
              '--format=json',
              '--coverage=${p.join(d.sandbox, 'empty.info')}',
              '-',
            ],
            out: stdinOut,
            err: stdinErr,
            input: Stream.value(utf8.encode('void f() {}')),
          ),
        ).equals(0);
        check(
          stdinErr.toString(),
        ).contains('Warning: --coverage is ignored for stdin ("-") targets.');
        final list = jsonDecode(stdinOut.toString()) as List<dynamic>;
        check(
          (list.single as Map<String, dynamic>).containsKey('coverage'),
        ).isFalse;
      },
    );
  });
}
