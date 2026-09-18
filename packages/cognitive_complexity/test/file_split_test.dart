import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:cognitive_complexity/cognitive_complexity.dart';
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

        const analyzer = FileSplitAnalyzer();
        final report = await analyzer.analyzeFile(
          file.path,
          targetLines: 35,
          minClusterLines: 15,
        );

        check(report.targetLines).equals(35);
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

      const analyzer = FileSplitAnalyzer();
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

    test('Propagates custom targetLines into FileSplitReport and enforces '
        'minClusterLines on mid-loop flush', () async {
      final file = File(p.join(tempDir.path, 'layer_flush.dart'));
      final padLarge = List.generate(55, (i) => '  final l$i = $i;').join('\n');
      final padMid = List.generate(37, (i) => '  final m$i = $i;').join('\n');
      // TinyLeaf (3 lines) + MidLeaf (39 lines) are both depth 0 leaves
      // referenced by RootCoordinator (59 lines).
      // With targetLines = 40 and minClusterLines = 25:
      // TinyLeaf (3) + MidLeaf (39) = 42 > 40 -> mid-loop flush occurs when
      // TinyLeaf (3 lines < minClusterLines 25) is in the batch.
      // TinyLeaf must NOT be emitted as a 3-line micro-cluster, while MidLeaf
      // (39 >= 25) SHOULD be extracted.
      file.writeAsStringSync('''
class TinyLeaf {
  final int x = 1;
}

class MidLeaf {
$padMid
}

class RootCoordinator {
  final TinyLeaf t = TinyLeaf();
  final MidLeaf m = MidLeaf();
$padLarge
}
''');

      const analyzer = FileSplitAnalyzer();
      final report = await analyzer.analyzeFile(
        file.path,
        targetLines: 40,
        minClusterLines: 25,
      );

      check(report.targetLines).equals(40);
      check(report.formatText()).contains(
        'exceeds target 40 lines — consider extracting cohesive methods',
      );
      for (final cluster in report.clusters) {
        check(cluster.totalLines).isGreaterOrEqual(25);
      }
      final extractedNames = report.clusters
          .expand((c) => c.declarations.map((d) => d.name))
          .toSet();
      check(extractedNames.contains('MidLeaf')).equals(true);
      check(extractedNames.contains('TinyLeaf')).equals(false);
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
