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

    test(
      'Merges sibling cones sharing private helpers to eliminate @internal crossings within budget',
      () async {
        final file = File(p.join(tempDir.path, 'gh_view_sim.dart'));
        final padOrch = List.generate(
          25,
          (i) => '  final o$i = $i;',
        ).join('\n');
        final padMd = List.generate(25, (i) => '  final m$i = $i;').join('\n');
        final padTerm = List.generate(
          25,
          (i) => '  final t$i = $i;',
        ).join('\n');
        final padFetch = List.generate(
          35,
          (i) => '  final f$i = $i;',
        ).join('\n');
        file.writeAsStringSync('''
class Orchestrator {
  void run() {
    DataFetcher().fetch();
    MarkdownRenderer().render();
    TerminalRenderer().render();
$padOrch
  }
}

class DataFetcher {
  void fetch() {
$padFetch
  }
}

class MarkdownRenderer {
  String render() {
$padMd
    return _statusLabel();
  }
}

class TerminalRenderer {
  String render() {
$padTerm
    return _statusLabel();
  }
}

String _statusLabel() {
  return 'OK';
}
''');

        const analyzer = FileSplitAnalyzer();
        final report = await analyzer.analyzeFile(
          file.path,
          targetLines: 80,
          minClusterLines: 20,
        );

        final rendererCluster = report.clusters.firstWhere(
          (c) => c.declarations.any((d) => d.name == 'MarkdownRenderer'),
        );
        final rendererDeclNames = rendererCluster.declarations
            .map((d) => d.name)
            .toSet();
        check(rendererDeclNames.contains('TerminalRenderer')).equals(true);
        check(rendererDeclNames.contains('_statusLabel')).equals(true);
        check(rendererCluster.tier).equals(SplitTier.tier1CleanLibrary);
        check(rendererCluster.privateTopLevelsToWiden).isEmpty();
        check(
          rendererCluster.absorbedPrivateHelpers.contains('_statusLabel'),
        ).equals(true);
      },
    );

    test(
      'Supports --use-parts, --no-use-parts, and default agent ask-user directive',
      () async {
        final file = File(p.join(tempDir.path, 'monolith_engine.dart'));
        final pad = List.generate(50, (i) => '  final x$i = $i;').join('\n');
        file.writeAsStringSync('''
class MonolithEngine {
$pad
}
''');

        const analyzer = FileSplitAnalyzer();

        // 1. Default (useParts: null): advises part/part of AND instructs agent to ask user
        final defaultReport = await analyzer.analyzeFile(
          file.path,
          targetLines: 30,
        );
        check(defaultReport.clusters).isEmpty();
        check(
          defaultReport.formatText(),
        ).contains('Explicitly ASK the user whether they prefer');

        // 2. Explicit --use-parts (useParts: true): emits Tier 3 part cluster without prompt
        final partsReport = await analyzer.analyzeFile(
          file.path,
          targetLines: 30,
          useParts: true,
        );
        check(partsReport.clusters.length).equals(1);
        check(
          partsReport.clusters.first.tier,
        ).equals(SplitTier.tier3PartDirective);
        check(partsReport.clusters.first.agentDirective).isNull();
        check(
          partsReport.clusters.first.zeroChurnExportDirective,
        ).equals("part '${partsReport.clusters.first.suggestedFileName}';");

        // 3. Explicit --no-use-parts (useParts: false): suppresses part/part of
        final noPartsReport = await analyzer.analyzeFile(
          file.path,
          targetLines: 30,
          useParts: false,
        );
        check(noPartsReport.clusters).isEmpty();
        check(noPartsReport.formatText()).contains('--no-use-parts active');
      },
    );
  });
}
