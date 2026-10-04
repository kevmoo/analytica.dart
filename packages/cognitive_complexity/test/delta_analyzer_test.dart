import 'dart:io';
import 'package:checks/checks.dart';
import 'package:cognitive_complexity/cognitive_complexity.dart';
import 'package:test/scaffolding.dart';

void main() {
  _compareBySignificanceTests();

  group('DeltaAnalyzer In-Memory Diffing', () {
    final analyzer = DeltaAnalyzer();

    test('Identifies improved function complexity (score decrease)', () {
      const oldCode = '''
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

      const newCode = '''
        int compute(int x) {
          if (x <= 0) return 0;
          if (x > 10) return 2;
          return 1;
        }
      ''';

      final deltas = analyzer.computeDeltaForCode(oldCode, newCode);
      check(deltas).length.equals(1);
      final d = deltas.first;
      check(d.name).equals('compute');
      check(d.oldScore).isNotNull().equals(3);
      check(d.newScore).isNotNull().equals(2);
      check(d.delta).equals(-1);
      check(d.status).equals(DeltaStatus.improved);
      check(d.isViolation(failThreshold: 15)).isFalse();
    });

    test('Identifies increased complexity and flags failure on increase', () {
      const oldCode = 'void foo() { print("clean"); }';
      const newCode = '''
        void foo() {
          if (a) {
            if (b) print("worse");
          }
        }
      ''';

      final deltas = analyzer.computeDeltaForCode(oldCode, newCode);
      check(deltas).length.equals(1);
      final d = deltas.first;
      check(d.name).equals('foo');
      check(d.oldScore).isNotNull().equals(0);
      check(d.newScore).isNotNull().equals(3);
      check(d.delta).equals(3);
      check(d.status).equals(DeltaStatus.increased);
      check(d.isViolation(failOnIncrease: true)).isTrue();
    });

    test('Threshold gates fail-on-increase when both are supplied', () {
      const oldCode = 'void foo() { print("clean"); }';
      const newCode = '''
        void foo() {
          if (a) {
            if (b) print("worse");
          }
        }
      ''';

      final d = analyzer.computeDeltaForCode(oldCode, newCode).first;
      check(d.newScore).isNotNull().equals(3);
      // Within budget: the increase is reported but is not a violation.
      check(d.isViolation(failOnIncrease: true, failThreshold: 15)).isFalse();
      // Over budget: the increase is a violation.
      check(d.isViolation(failOnIncrease: true, failThreshold: 2)).isTrue();
      // No threshold: strict any-increase ratchet.
      check(d.isViolation(failOnIncrease: true)).isTrue();
    });

    test('Identifies newly added and removed functions across diff', () {
      const oldCode = 'void deletedFunc(int a) { if (a > 0) print(a); }';
      const newCode = 'void addedFunc(bool b) { if (b) print(1); }';

      final deltas = analyzer.computeDeltaForCode(oldCode, newCode);
      check(deltas).length.equals(2);

      final added = deltas.firstWhere((d) => d.name == 'addedFunc');
      check(added.status).equals(DeltaStatus.added);
      check(added.oldScore).isNull();
      check(added.newScore).isNotNull().equals(1);

      final removed = deltas.firstWhere((d) => d.name == 'deletedFunc');
      check(removed.status).equals(DeltaStatus.removed);
      check(removed.oldScore).isNotNull().equals(1);
      check(removed.newScore).isNull();
    });

    test('fail-on-increase ignores newly added functions', () {
      const oldCode = 'void existing() {}';
      const newCode = '''
        void existing() {}
        void brandNew(bool a) { if (a) print(1); }
      ''';

      final deltas = analyzer.computeDeltaForCode(oldCode, newCode);
      final added = deltas.firstWhere((d) => d.name == 'brandNew');
      check(added.status).equals(DeltaStatus.added);
      // A new function has no baseline to increase from; it is governed by
      // the fail threshold instead.
      check(added.isViolation(failOnIncrease: true)).isFalse();
      check(added.isViolation(failOnIncrease: true, failThreshold: 0)).isTrue();
    });
  });

  group('GitHubReporter Annotation Emissions', () {
    test(
      'Does not emit workflow warning annotations for non-violating increases',
      () {
        final outBuf = StringBuffer();
        final reporter = GitHubReporter(stdoutSink: outBuf);

        const delta = ComplexityDelta(
          filePath: 'lib/service.dart',
          name: 'Service.execute',
          startLine: 12,
          endLine: 40,
          oldScore: 5,
          newScore: 10,
          status: DeltaStatus.increased,
        );

        const summary = DeltaSummary(
          baseRef: 'main',
          targetRef: 'HEAD',
          filesAnalyzed: 1,
          deltas: [delta],
        );

        reporter.printReport(deltaSummary: summary, failThreshold: 15);
        check(outBuf.toString()).not((s) => s.contains('::warning'));
        check(outBuf.toString()).not((s) => s.contains('::error'));
      },
    );

    test('Emits workflow error annotations when failure thresholds breach', () {
      final outBuf = StringBuffer();
      final reporter = GitHubReporter(stdoutSink: outBuf);

      const delta = ComplexityDelta(
        filePath: 'lib/parser.dart',
        name: 'Parser.parse',
        startLine: 1,
        endLine: 80,
        oldScore: 10,
        newScore: 25,
        status: DeltaStatus.increased,
      );

      const summary = DeltaSummary(
        baseRef: 'origin/main',
        targetRef: 'HEAD',
        filesAnalyzed: 1,
        deltas: [delta],
      );

      reporter.printReport(deltaSummary: summary, failThreshold: 15);
      check(outBuf.toString()).contains(
        '::error file=lib/parser.dart,line=1,'
        'title=Cognitive Complexity Violation::Parser.parse was '
        'increased in complexity (+15 points) to score 25.',
      );
    });

    test(
      'Omits 0-score added/removed rows and renders _new_ and _deleted_ scores',
      () {
        final summaryFile = Directory.systemTemp.createTempSync('cc_test_');
        addTearDown(() => summaryFile.deleteSync(recursive: true));
        final mdFile = File('${summaryFile.path}/summary.md');
        final reporter = GitHubReporter(summaryFile: mdFile);

        const summary = DeltaSummary(
          baseRef: 'origin/main',
          targetRef: 'HEAD',
          filesAnalyzed: 1,
          deltas: [
            ComplexityDelta(
              filePath: 'lib/a.dart',
              name: 'addedWithScore',
              startLine: 1,
              endLine: 10,
              oldScore: null,
              newScore: 5,
              status: DeltaStatus.added,
            ),
            ComplexityDelta(
              filePath: 'lib/a.dart',
              name: 'addedZeroScore',
              startLine: 12,
              endLine: 15,
              oldScore: null,
              newScore: 0,
              status: DeltaStatus.added,
            ),
            ComplexityDelta(
              filePath: 'lib/a.dart',
              name: 'deletedWithScore',
              startLine: 20,
              endLine: 30,
              oldScore: 4,
              newScore: null,
              status: DeltaStatus.removed,
            ),
            ComplexityDelta(
              filePath: 'lib/a.dart',
              name: 'deletedZeroScore',
              startLine: 32,
              endLine: 35,
              oldScore: 0,
              newScore: null,
              status: DeltaStatus.removed,
            ),
          ],
        );

        check(summary.countAdded).equals(1);
        check(summary.countRemoved).equals(1);
        check(summary.netDelta).equals(1);

        final json = summary.toJson(failThreshold: 15);
        final summaryJson = json['summary'] as Map<String, dynamic>;
        check(summaryJson['added']).equals(1);
        check(summaryJson['removed']).equals(1);
        check(summaryJson['declarations_changed']).equals(2);

        reporter.printReport(deltaSummary: summary, failThreshold: 15);
        final rendered = mdFile.readAsStringSync();
        check(rendered)
          ..contains(
            '**Net Delta**: +1 | **Added**: 1 | **Increased**: 0 | '
            '**Improved**: 0 | **Removed**: 1 | **Violations**: 0',
          )
          ..contains(
            '| 🔵 | `addedWithScore` | `lib/a.dart:L1-10` | `+5` | '
            '_new_ -> **5** |',
          )
          ..contains(
            '| 🗑️ | `deletedWithScore` | `lib/a.dart` | `-4` | '
            '4 -> _deleted_ |',
          )
          ..not((s) => s.contains('addedZeroScore'))
          ..not((s) => s.contains('deletedZeroScore'));
      },
    );
  });

  group('DeltaAnalyzer with Mocked GitDiffService', () {
    test(
      'computes deltas for mocked modified files and returns sorted summary',
      () async {
        const fakeGit = FakeGitDiffService(
          modifiedFiles: ['lib/foo.dart', 'lib/bar.dart'],
          historicalContent: {
            'lib/foo.dart': 'void main() { if (a) { if (b) {} } }', // score 3
            'lib/bar.dart': 'void run() {}', // score 0
          },
          currentContent: {
            'lib/foo.dart': 'void main() { if (a) {} }', // score 1 (delta -2)
            'lib/bar.dart':
                'void run() { if (a) { if (b) {} } }', // score 3 (delta +3)
          },
        );

        final analyzer = DeltaAnalyzer(gitService: fakeGit);
        final summary = await analyzer.computeDeltas('main');

        check(summary.filesAnalyzed).equals(2);
        check(summary.deltas).length.equals(2);

        // Sorting order: new score descending (3 first, then 1)
        final first = summary.deltas[0];
        check(first.name).equals('run');
        check(first.delta).equals(3);
        check(first.status).equals(DeltaStatus.increased);

        final second = summary.deltas[1];
        check(second.name).equals('main');
        check(second.delta).equals(-2);
        check(second.status).equals(DeltaStatus.improved);
      },
    );

    test(
      'ranks a small-delta violation above large-delta additions that pass',
      () async {
        // A nested chain of N `if`s scores 1 + 2 + ... + N.
        String nested(String name, int depth) {
          final open = List.generate(depth, (i) => 'if (a$i) {').join(' ');
          final close = '}' * depth;
          return 'void $name() { $open $close }';
        }

        final fakeGit = FakeGitDiffService(
          modifiedFiles: ['lib/legacy.dart', 'lib/fresh.dart'],
          historicalContent: {
            // 1+2+3+4+5 = 15: sits exactly at the ceiling.
            'lib/legacy.dart': nested('legacy', 5),
            'lib/fresh.dart': '',
          },
          currentContent: {
            // 15 -> 21: delta +6, but now a violation.
            'lib/legacy.dart': nested('legacy', 6),
            // Two brand-new functions at 10 (delta +10 each, no violation).
            'lib/fresh.dart': '${nested('freshB', 4)}\n${nested('freshA', 4)}',
          },
        );

        final analyzer = DeltaAnalyzer(gitService: fakeGit);
        final summary = await analyzer.computeDeltas('main', failThreshold: 15);

        check(summary.deltas.map((d) => d.name).toList()).deepEquals([
          'legacy', // violation first despite the smaller delta
          'freshA', // then by score, with path/name tie-breaks
          'freshB',
        ]);
        check(summary.deltas.first.delta).equals(6);
        check(summary.deltas[1].delta).equals(10);

        // Without a threshold nothing is a violation, so score wins outright.
        final unthresholded = await analyzer.computeDeltas('main');
        check(
          unthresholded.deltas.map((d) => d.name).toList(),
        ).deepEquals(['legacy', 'freshA', 'freshB']);
      },
    );

    test('computes file line deltas and respects opt-in ratchet and '
        'ignore directives', () async {
      final analyzer = ComplexityAnalyzer();
      final lines = List.generate(80, (i) => '  final v$i = $i;').join('\n');
      final code = 'void longFunction() {\n$lines\n}\n';
      final results = analyzer.analyzeCode(code, filePath: 'long.dart');

      check(results).length.equals(1);
      check(results.first.lineCount).isGreaterThan(80);
      check(
        results.first.isViolation(failThreshold: 15, maxFunctionLines: null),
      ).isFalse();
      check(
        results.first.isViolation(failThreshold: 15, maxFunctionLines: 60),
      ).isTrue();

      // File-level and declaration-level ignore directives
      const ignoredFileCode = '''
// cognitive_complexity:ignore_for_file
void complexFunc(bool a, bool b) {
  if (a) {
    if (b) {}
  }
}
''';
      check(analyzer.analyzeCode(ignoredFileCode)).isEmpty();
      check(analyzer.analyzeCodeLineCount(ignoredFileCode)).isNull();

      const ignoredDeclCode = '''
// cognitive_complexity:ignore
void ignoredFunc(bool a, bool b) {
  if (a) {
    if (b) {}
  }
}

void activeFunc(bool a) {
  if (a) {}
}
''';
      final partial = analyzer.analyzeCode(ignoredDeclCode);
      check(partial).length.equals(1);
      check(partial.first.name).equals('activeFunc');

      const summary = DeltaSummary(
        baseRef: 'HEAD~1',
        targetRef: 'HEAD',
        filesAnalyzed: 2,
        deltas: [
          ComplexityDelta(
            filePath: 'a.dart',
            name: 'fn',
            startLine: 1,
            endLine: 100,
            oldScore: 2,
            newScore: 2,
            oldLines: 90,
            newLines: 100,
            status: DeltaStatus.unchanged,
          ),
        ],
        fileDeltas: [
          FileLineDelta(
            filePath: 'a.dart',
            oldLines: 450,
            newLines: 460,
            status: DeltaStatus.increased,
          ),
          FileLineDelta(
            filePath: 'legacy.dart',
            oldLines: 500,
            newLines: 450,
            status: DeltaStatus.improved,
          ),
        ],
      );

      check(
        summary.isClean(
          failThreshold: 15,
          maxFileLines: null,
          maxFunctionLines: null,
          failOnIncrease: true,
        ),
      ).isTrue();

      check(
        summary.isClean(
          failThreshold: 15,
          maxFileLines: 400,
          maxFunctionLines: null,
          failOnIncrease: true,
        ),
      ).isFalse();

      final json = summary.toJson(
        failThreshold: 15,
        maxFileLines: 400,
        maxFunctionLines: 80,
      );
      final summaryMap = json['summary'] as Map<String, dynamic>;
      check(summaryMap['file_line_violations']).equals(1);
      check((json['file_deltas'] as List).length).equals(2);

      // GitHubReporter renders file and declaration line limit violations
      final ghOut = StringBuffer();
      final reporter = GitHubReporter(stdoutSink: ghOut);
      reporter.printReport(
        deltaSummary: summary,
        failThreshold: 15,
        maxFileLines: 400,
        maxFunctionLines: 80,
      );
      check(ghOut.toString())
        ..contains('title=File Line Limit Violation::a.dart grew to 460')
        ..contains(
          'title=Declaration Line Limit Violation::fn spans 100 lines',
        );
    });
  });
}

void _compareBySignificanceTests() {
  ComplexityDelta delta(
    String name, {
    int? oldScore,
    int? newScore,
    String file = 'lib/a.dart',
    int line = 1,
    DeltaStatus status = DeltaStatus.increased,
  }) => ComplexityDelta(
    filePath: file,
    name: name,
    startLine: line,
    endLine: line,
    oldScore: oldScore,
    newScore: newScore,
    status: status,
  );

  group('compareBySignificance', () {
    test('violation outranks a higher score that passes', () {
      final violating = delta('v', oldScore: 20, newScore: 22);
      final passing = delta(
        'p',
        oldScore: null,
        newScore: 30,
        status: DeltaStatus.improved,
      );
      // 30 is "improved"-status, so not a violation even though it is high.
      check(
        compareBySignificance(violating, passing, failThreshold: 15),
      ).isLessThan(0);
      // Without a threshold, raw score decides.
      check(compareBySignificance(violating, passing)).isGreaterThan(0);
    });

    test('score beats delta, delta beats location', () {
      final big = delta('big', oldScore: 10, newScore: 12);
      final small = delta('small', oldScore: 0, newScore: 11);
      check(compareBySignificance(big, small)).isLessThan(0);

      final steep = delta('steep', oldScore: 0, newScore: 11);
      final gentle = delta('gentle', oldScore: 9, newScore: 11);
      check(compareBySignificance(steep, gentle)).isLessThan(0);

      final earlier = delta('x', oldScore: 0, newScore: 5, line: 3);
      final later = delta('x', oldScore: 0, newScore: 5, line: 9);
      check(compareBySignificance(earlier, later)).isLessThan(0);
      check(compareBySignificance(later, earlier)).isGreaterThan(0);
      check(compareBySignificance(earlier, earlier)).equals(0);
    });

    test('removed declarations sink to the bottom', () {
      final removed = delta(
        'gone',
        oldScore: 40,
        newScore: null,
        status: DeltaStatus.removed,
      );
      final tiny = delta('tiny', oldScore: 0, newScore: 1);
      check(compareBySignificance(tiny, removed)).isLessThan(0);
    });
  });
}

class FakeGitDiffService extends GitDiffService {
  final List<String> modifiedFiles;
  final Map<String, String> historicalContent;
  final Map<String, String> currentContent;

  const FakeGitDiffService({
    required this.modifiedFiles,
    required this.historicalContent,
    required this.currentContent,
  });

  @override
  Future<String> getRepoRoot() async => '/root';

  @override
  Future<String> getMergeBase(String baseRef) async => 'mock-merge-base';

  @override
  Future<List<String>> getModifiedDartFiles(
    String baseRef, {
    List<String> targetPaths = const [],
  }) async => modifiedFiles;

  @override
  Future<String> getHistoricalFileContent(
    String baseRef,
    String relativePath,
  ) async => historicalContent[relativePath] ?? '';

  @override
  Future<String> getCurrentFileContent(String relativePath) async =>
      currentContent[relativePath] ?? '';
}
