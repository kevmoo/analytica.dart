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

    test('Merges sibling cones sharing private helpers to eliminate '
        '@internal crossings within budget', () async {
      final file = File(p.join(tempDir.path, 'gh_view_sim.dart'));
      final padOrch = List.generate(25, (i) => '  final o$i = $i;').join('\n');
      final padMd = List.generate(25, (i) => '  final m$i = $i;').join('\n');
      final padTerm = List.generate(25, (i) => '  final t$i = $i;').join('\n');
      final padFetch = List.generate(35, (i) => '  final f$i = $i;').join('\n');
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
    });

    test('Supports --use-parts, --no-use-parts, and default agent '
        'ask-user directive', () async {
      final file = File(p.join(tempDir.path, 'monolith_engine.dart'));
      final pad = List.generate(50, (i) => '  final x$i = $i;').join('\n');
      file.writeAsStringSync('''
class MonolithEngine {
$pad
}
''');

      const analyzer = FileSplitAnalyzer();

      // 1. Default (useParts: null): advises part/part of + ask-user prompt
      final defaultReport = await analyzer.analyzeFile(
        file.path,
        targetLines: 30,
      );
      check(defaultReport.clusters).isEmpty();
      check(
        defaultReport.formatText(),
      ).contains('Explicitly ASK the user whether they prefer');

      // 2. Explicit --use-parts (useParts: true): emits Tier 3 part cluster
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
    });

    test('Advises promoting static methods inside oversized classes to '
        'top-level functions', () async {
      final file = File(p.join(tempDir.path, 'static_monolith.dart'));
      final pad = List.generate(20, (i) => '    final v$i = $i;').join('\n');
      file.writeAsStringSync('''
class StaticMonolith {
  void execute() {
    _helperOne();
    _helperTwo();
  }

  static void _helperOne() {
$pad
  }

  static void _helperTwo() {
$pad
  }
}
''');

      const analyzer = FileSplitAnalyzer();
      final report = await analyzer.analyzeFile(file.path, targetLines: 30);
      final decl = report.survivingDeclarations.single;
      check(decl.staticMethodCount).equals(2);
      check(decl.staticMethodLines).isGreaterThan(40);
      check(report.formatText()).contains(
        'contains 2 static method(s) (~${decl.staticMethodLines} lines) '
        'that can be promoted to top-level functions',
      );
    });

    test('Dynamically re-evaluates shared-tail diamond cones so surviving '
        'file drops below targetLines', () async {
      final file = File(p.join(tempDir.path, 'diamond_harvester.dart'));
      final padRunner = List.generate(
        25,
        (i) => '  final r$i = $i;',
      ).join('\n');
      final padSubA = List.generate(25, (i) => '  final a$i = $i;').join('\n');
      final padSubB = List.generate(30, (i) => '  final b$i = $i;').join('\n');
      final padShared = List.generate(
        20,
        (i) => '  final s$i = $i;',
      ).join('\n');
      file.writeAsStringSync('''
class HarvestRunner {
  void run() {
    _scanCalendar();
    _scanTranscripts();
$padRunner
  }
}

void _scanCalendar() {
  _sharedClassifier();
$padSubA
}

void _scanTranscripts() {
  _sharedClassifier();
$padSubB
}

void _sharedClassifier() {
$padShared
}
''');

      const analyzer = FileSplitAnalyzer();
      final report = await analyzer.analyzeFile(
        file.path,
        targetLines: 55,
        minClusterLines: 20,
      );

      check(report.clusters.length).equals(2);
      check(report.estimatedRemainingLines).isLessOrEqual(55);
    });

    test('Re-absorbs surplus small cuts when larger cuts already satisfy '
        'targetLines', () async {
      final file = File(p.join(tempDir.path, 'email_cmd_sim.dart'));
      final padMain = List.generate(28, (i) => '  final m$i = $i;').join('\n');
      final padLeaf = List.generate(18, (i) => '  final l$i = $i;').join('\n');
      final padBig = List.generate(42, (i) => '  final b$i = $i;').join('\n');
      file.writeAsStringSync('''
class MainEmailCommand {
  void run() {
    smallHelper();
    HeavyCleanupCommand().cleanup();
$padMain
  }
}

void smallHelper() {
$padLeaf
}

class HeavyCleanupCommand {
  void cleanup() {
    _cleanupStep();
$padBig
  }
}

void _cleanupStep() {
  final c = 1;
}
''');

      const analyzer = FileSplitAnalyzer();
      final report = await analyzer.analyzeFile(
        file.path,
        targetLines: 60,
        minClusterLines: 15,
      );

      // Extracting HeavyCleanupCommand (~52L) alone brings total (~105L) down
      // to ~53L (<= 60L), so smallHelper (~21L) is re-absorbed into surviving!
      check(report.clusters.length).equals(1);
      final survivingNames = report.survivingDeclarations
          .map((d) => d.name)
          .toSet();
      check(survivingNames.contains('smallHelper')).equals(true);
      check(report.estimatedRemainingLines).isLessOrEqual(60);
    });

    test('Detects embedded string/asset literals (>75% of declaration) '
        'and supports multi-file CLI batch execution', () async {
      final assetFile = File(p.join(tempDir.path, 'dashboard_js.dart'));
      final adjacentLines = List.generate(
        40,
        (i) => "    'const line$i = $i;\\n'",
      ).join('\n');
      assetFile.writeAsStringSync('''
class DashboardJs {
  static const String script =
$adjacentLines;
}
''');

      final generatedFile = File(p.join(tempDir.path, 'big.g.dart'));
      final genLines = List.generate(50, (i) => 'final g$i = $i;').join('\n');
      generatedFile.writeAsStringSync(genLines);

      final secondFile = File(p.join(tempDir.path, 'second_target.dart'));
      final pad = List.generate(25, (i) => '  final x$i = $i;').join('\n');
      secondFile.writeAsStringSync('''
class Alpha {
  final Beta b = Beta();
$pad
}
class Beta {
$pad
}
''');

      final out = StringBuffer();
      final err = StringBuffer();
      final code = await file_split_cli.runFileSplitCli(
        ['--target-lines', '30', '--min-cluster-lines', '15', tempDir.path],
        out: out,
        err: err,
      );

      check(code).equals(0);
      final text = out.toString();
      check(
        text,
      ).contains('embedded string/asset literals (>75% of declaration)');
      check(text).contains('second_target.dart');
      check(text.contains('big.g.dart')).equals(false);

      final emptyOut = StringBuffer();
      await file_split_cli.runFileSplitCli(
        ['--target-lines', '5000', tempDir.path],
        out: emptyOut,
        err: err,
      );
      check(
        emptyOut.toString(),
      ).contains('No files exceeding 5000 lines found.');
    });
  });
}
