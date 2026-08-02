import 'package:checks/checks.dart';
import 'package:cognitive_complexity/cognitive_complexity.dart';
import 'package:test/scaffolding.dart';

void main() {
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
  });

  group('GitHubReporter Annotation Emissions', () {
    test('Emits workflow warning annotations for increased complexity', () {
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

      final summary = DeltaSummary(
        baseRef: 'main',
        targetRef: 'HEAD',
        filesAnalyzed: 1,
        deltas: [delta],
      );

      reporter.printReport(deltaSummary: summary);
      check(outBuf.toString()).contains(
        '::warning file=lib/service.dart,line=12,endLine=40,'
        'title=Cognitive Complexity Increased (+5)::Service.execute '
        'increased from 5 to 10 (+5 points).',
      );
    });

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

      final summary = DeltaSummary(
        baseRef: 'origin/main',
        targetRef: 'HEAD',
        filesAnalyzed: 1,
        deltas: [delta],
      );

      reporter.printReport(deltaSummary: summary, failThreshold: 15);
      check(outBuf.toString()).contains(
        '::error file=lib/parser.dart,line=1,endLine=80,'
        'title=Cognitive Complexity Violation::Parser.parse was '
        'increased in complexity (+15 points) to score 25.',
      );
    });
  });
}
