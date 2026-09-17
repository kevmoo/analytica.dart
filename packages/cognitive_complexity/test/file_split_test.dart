import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:cognitive_complexity/cognitive_complexity.dart';
import 'package:cognitive_complexity/src/complexity/cli.dart' as complexity_cli;
import 'package:cognitive_complexity/src/file_split/cli.dart' as file_split_cli;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('file_split_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('Opt-In File & Function Line Limits', () {
    test('Default null limits do not flag long files or long functions', () {
      final analyzer = ComplexityAnalyzer();
      final lines = List.generate(80, (i) => '  final v$i = $i;').join('\n');
      final code = 'void longFunction() {\n$lines\n}\n';
      final results = analyzer.analyzeCode(code, filePath: 'long.dart');

      check(results).length.equals(1);
      check(results.first.lineCount).isGreaterThan(80);
      check(
        results.first.isViolation(failThreshold: 15, maxFunctionLines: null),
      ).equals(false);
      check(
        results.first.isViolation(failThreshold: 15, maxFunctionLines: 60),
      ).equals(true);
    });

    test('CLI --max-file-lines and --max-function-lines are opt-in', () async {
      final file = File(p.join(tempDir.path, 'sample.dart'));
      final body = List.generate(30, (i) => '  final x$i = $i;').join('\n');
      file.writeAsStringSync('void bigDecl() {\n$body\n}\n');

      final outDefault = StringBuffer();
      final errDefault = StringBuffer();
      final codeDefault = await complexity_cli.runCli(
        [file.path],
        out: outDefault,
        err: errDefault,
      );
      check(codeDefault).equals(0);

      final outFileVio = StringBuffer();
      final errFileVio = StringBuffer();
      final codeFileVio = await complexity_cli.runCli(
        ['--max-file-lines', '20', file.path],
        out: outFileVio,
        err: errFileVio,
      );
      check(codeFileVio).equals(1);
      check(
        outFileVio.toString(),
      ).contains('File Line Violations (> 20 lines)');

      final outFuncVio = StringBuffer();
      final errFuncVio = StringBuffer();
      final codeFuncVio = await complexity_cli.runCli(
        ['--max-function-lines', '20', file.path],
        out: outFuncVio,
        err: errFuncVio,
      );
      check(codeFuncVio).equals(1);
      check(outFuncVio.toString()).contains('[VIOLATION]');
    });

    test('DeltaSummary.isClean respects opt-in pragmatic ratchet', () {
      const cleanWhenNull = DeltaSummary(
        baseRef: 'HEAD~1',
        targetRef: 'HEAD',
        filesAnalyzed: 1,
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
        ],
      );

      final isCleanNull = cleanWhenNull.isClean(
        failThreshold: 15,
        maxFileLines: null,
        maxFunctionLines: null,
        failOnIncrease: true,
      );
      check(isCleanNull).equals(true);

      final isCleanOptIn = cleanWhenNull.isClean(
        failThreshold: 15,
        maxFileLines: 400,
        maxFunctionLines: null,
        failOnIncrease: true,
      );
      check(isCleanOptIn).equals(false);

      // Shrinking a legacy >400-line file passes when failOnIncrease is true.
      const shrinkingLegacy = DeltaSummary(
        baseRef: 'HEAD~1',
        targetRef: 'HEAD',
        filesAnalyzed: 1,
        deltas: [],
        fileDeltas: [
          FileLineDelta(
            filePath: 'legacy.dart',
            oldLines: 500,
            newLines: 450,
            status: DeltaStatus.improved,
          ),
        ],
      );
      final isCleanShrinking = shrinkingLegacy.isClean(
        failThreshold: 15,
        maxFileLines: 400,
        maxFunctionLines: null,
        failOnIncrease: true,
      );
      check(isCleanShrinking).equals(true);
    });
  });

  group('FileSplitAnalyzer & CLI', () {
    test(
      'Detects disjoint LCOM4 islands and single-dominator absorption',
      () async {
        final file = File(p.join(tempDir.path, 'mixed_service.dart'));
        final padA = List.generate(35, (i) => '  final a$i = $i;').join('\n');
        final padB = List.generate(20, (i) => '  final b$i = $i;').join('\n');
        file.writeAsStringSync('''
class PrimaryService {
  void run() {
$padA
  }
}

class UnrelatedAnalytics {
  void record() {
    _formatMetric();
$padB
  }
}

String _formatMetric() {
  return 'metric';
}
''');

        final analyzer = FileSplitAnalyzer();
        final report = await analyzer.analyzeFile(
          file.path,
          targetLines: 35,
          minClusterLines: 15,
        );

        check(report.lcom4Islands).equals(2);
        check(report.clusters.isNotEmpty).equals(true);

        final cut = report.clusters.first;
        check(cut.tier).equals(SplitTier.tier1CleanLibrary);
        final declNames = cut.declarations.map((d) => d.name).toList();
        check(declNames.contains('UnrelatedAnalytics')).equals(true);
        check(
          cut.absorbedPrivateHelpers.contains('_formatMetric'),
        ).equals(true);
        check(
          cut.zeroChurnExportDirective,
        ).equals("export '${cut.suggestedFileName}' show UnrelatedAnalytics;");
      },
    );

    test('Keeps sealed class and direct subtypes fused together', () async {
      final file = File(p.join(tempDir.path, 'result_model.dart'));
      final pad = List.generate(25, (i) => '  final v$i = $i;').join('\n');
      file.writeAsStringSync('''
sealed class ResultState {}

final class SuccessState extends ResultState {
$pad
}

final class ErrorState extends ResultState {
$pad
}

class ConsumerEngine {
  ResultState execute() => SuccessState();
$pad
}
''');

      final analyzer = FileSplitAnalyzer();
      final report = await analyzer.analyzeFile(
        file.path,
        targetLines: 40,
        minClusterLines: 15,
      );

      for (final cluster in report.clusters) {
        final names = cluster.declarations.map((d) => d.name).toSet();
        if (names.contains('ResultState')) {
          check(names.contains('SuccessState')).equals(true);
          check(names.contains('ErrorState')).equals(true);
        }
      }
    });

    test('runFileSplitCli supports text and json output formats', () async {
      final file = File(p.join(tempDir.path, 'cli_target.dart'));
      final pad = List.generate(30, (i) => '  final n$i = $i;').join('\n');
      file.writeAsStringSync('''
class MainCoordinator {
  final LeafModel model = LeafModel();
$pad
}

class LeafModel {
$pad
}
''');

      final jsonOut = StringBuffer();
      final jsonErr = StringBuffer();
      final code = await file_split_cli.runFileSplitCli(
        [
          '--format',
          'json',
          '--target-lines',
          '35',
          '--min-cluster-lines',
          '15',
          file.path,
        ],
        out: jsonOut,
        err: jsonErr,
      );
      check(code).equals(0);
      final decoded = jsonDecode(jsonOut.toString()) as Map<String, dynamic>;
      check(decoded['declaration_count']).equals(2);
      check((decoded['clusters'] as List).isNotEmpty).equals(true);
    });
  });
}
