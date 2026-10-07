import 'dart:convert';
import 'dart:io';

import 'package:analytica/analyzer.dart';
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
      final decoded = jsonDecode(jsonOut.toString()) as List<dynamic>;
      final report = decoded.single as Map<String, dynamic>;
      check(report['declaration_count']).equals(2);
      check((report['clusters'] as List).isNotEmpty).equals(true);

      // A directory scan with no oversized files still yields an (empty)
      // array, never an object. (Explicit file paths are always analyzed.)
      final onlyDir = Directory(p.join(tempDir.path, 'json_shape_dir'))
        ..createSync();
      file.copySync(p.join(onlyDir.path, 'small.dart'));
      final emptyOut = StringBuffer();
      final emptyCode = await file_split_cli.runFileSplitCli(
        ['--format', 'json', '--target-lines', '5000', onlyDir.path],
        out: emptyOut,
        err: StringBuffer(),
      );
      check(emptyCode).equals(0);
      check(jsonDecode(emptyOut.toString())).isA<List<dynamic>>().isEmpty();
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

    test('Reports the implemented interface and suppresses the static-'
        'promotion hint when >= half of the members are @override', () async {
      final file = File(p.join(tempDir.path, 'interface_bound.dart'));
      final pad = List.generate(8, (i) => '    final v$i = $i;').join('\n');
      final overrides = List.generate(
        4,
        (i) => '  @override\n  void op$i() {\n$pad\n  }\n',
      ).join('\n');
      file.writeAsStringSync('''
abstract class Store {
  void op0();
  void op1();
  void op2();
  void op3();
}

class SqlStore implements Store {
$overrides
  static int _encode(int v) => v + 1;

  static int _decode(int v) => v - 1;

  int roundTrip(int v) => _decode(_encode(v));
}
''');

      const analyzer = FileSplitAnalyzer();
      final report = await analyzer.analyzeFile(file.path, targetLines: 30);
      final decl = report.survivingDeclarations.singleWhere(
        (d) => d.name == 'SqlStore',
      );
      check(decl.supertypeLabel).equals('implements Store');
      check(decl.memberCount).equals(7);
      check(decl.overrideMemberCount).equals(4);
      check(decl.staticMethodCount).equals(2);
      check(decl.isInterfaceBound).isTrue();
      final json = decl.toJson();
      check(json['supertype']).equals('implements Store');
      check(json['member_count']).equals(7);
      check(json['override_member_count']).equals(4);
      final text = report.formatText();
      check(text).contains(
        'implements Store (4/7 members are @override), so its size is '
        'bound by the interface surface;',
      );
      check(text).not((it) => it.contains('can be promoted'));
    });

    test('Reports `extends` facts but keeps the static-promotion hint when '
        'overrides are a minority', () async {
      final file = File(p.join(tempDir.path, 'subclass_monolith.dart'));
      final pad = List.generate(14, (i) => '    final v$i = $i;').join('\n');
      file.writeAsStringSync('''
class Base {
  void run() {}
}

class Worker extends Base {
  @override
  void run() => _helperOne();

  void other() => _helperTwo();

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
      final decl = report.survivingDeclarations.singleWhere(
        (d) => d.name == 'Worker',
      );
      check(decl.supertypeLabel).equals('extends Base');
      check(decl.isInterfaceBound).isFalse();
      final text = report.formatText();
      check(text).contains('extends Base (1/4 members are @override); ');
      check(text).contains('contains 2 static method(s)');
      check(text).not((it) => it.contains('bound by the interface surface'));
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

    test('Budget counts physical lines, not just declaration lines', () async {
      final file = File(p.join(tempDir.path, 'header_heavy.dart'));
      // ~45 lines of header (license, doc comments, imports, blank lines)
      // plus two unrelated 30-line classes. Declaration lines sum to ~64
      // (under target 80), but the physical file is ~110 lines (over target).
      final header = List.generate(45, (i) => '// header line $i').join('\n');
      final pad = List.generate(28, (i) => '  final v$i = $i;').join('\n');
      file.writeAsStringSync('''
$header

class CoreEngine {
$pad
}

class SideUtility {
$pad
}
''');

      const analyzer = FileSplitAnalyzer();
      final report = await analyzer.analyzeFile(
        file.path,
        targetLines: 80,
        minClusterLines: 15,
      );

      check(report.totalLines).isGreaterThan(80);
      check(report.clusters.length).equals(1);
      check(
        report.clusters.single.declarations.map((d) => d.name).toList(),
      ).deepEquals(['SideUtility']);
      check(report.estimatedRemainingLines).isLessOrEqual(80);
    });

    test(
      'Suggested filename follows the dominant public declaration',
      () async {
        final file = File(p.join(tempDir.path, 'naming_target.dart'));
        final padSmall = List.generate(
          6,
          (i) => '  final s$i = $i;',
        ).join('\n');
        final padBig = List.generate(30, (i) => '  final b$i = $i;').join('\n');
        final padRoot = List.generate(
          30,
          (i) => '  final r$i = $i;',
        ).join('\n');
        // TinyFirst appears first in source order; BigDominant is 4x larger.
        // Both land in the same cut because RootUser depends on both.
        file.writeAsStringSync('''
class TinyFirst {
$padSmall
}

class BigDominant {
  final TinyFirst t = TinyFirst();
$padBig
}

class RootUser {
  final BigDominant b = BigDominant();
$padRoot
}
''');

        const analyzer = FileSplitAnalyzer();
        final report = await analyzer.analyzeFile(
          file.path,
          targetLines: 50,
          minClusterLines: 15,
        );

        final cut = report.clusters.firstWhere(
          (c) => c.declarations.any((d) => d.name == 'BigDominant'),
        );
        check(
          cut.declarations.map((d) => d.name).toList(),
        ).deepEquals(['TinyFirst', 'BigDominant']);
        check(cut.suggestedFileName).equals('big_dominant.dart');
      },
    );

    test(
      'Splits a cone whose root only bridges unrelated components',
      () async {
        final file = File(p.join(tempDir.path, 'bridge_core.dart'));
        final padTop = List.generate(58, (i) => '  final t$i = $i;').join('\n');
        final padBridge = List.generate(
          16,
          (i) => '  final g$i = $i;',
        ).join('\n');
        final padLeaf = List.generate(
          38,
          (i) => '  final l$i = $i;',
        ).join('\n');
        // Top (61L) -> Bridge (21L) -> {AlphaStore (40L)} and
        //                              {BetaRenderer (40L) + BetaTheme (3L)}.
        // The two leaf groups share no edges, so the 104L Bridge cone is
        // really two unrelated components held together by Bridge. Bridge
        // has two edges into the Beta side and one into Alpha, so it travels
        // with Beta; Alpha is committed first because Beta's group depends
        // on it through Bridge.
        file.writeAsStringSync('''
class Top {
  final Bridge b = Bridge();
$padTop
}

class Bridge {
  final AlphaStore a = AlphaStore();
  final BetaRenderer r = BetaRenderer();
  final BetaTheme t = BetaTheme();
$padBridge
}

class AlphaStore {
$padLeaf
}

class BetaRenderer {
  final BetaTheme theme = BetaTheme();
$padLeaf
}

class BetaTheme {
  final int accent = 1;
}
''');

        const analyzer = FileSplitAnalyzer();
        final report = await analyzer.analyzeFile(
          file.path,
          targetLines: 110,
          minClusterLines: 20,
        );

        check(
          report.clusters.map((c) => c.suggestedFileName).toList(),
        ).deepEquals(['alpha_store.dart', 'beta_renderer.dart']);
        check(
          report.clusters[0].declarations.map((d) => d.name).toList(),
        ).deepEquals(['AlphaStore']);
        check(
          report.clusters[1].declarations.map((d) => d.name).toList(),
        ).deepEquals(['Bridge', 'BetaRenderer', 'BetaTheme']);
        for (final cluster in report.clusters) {
          check(cluster.tier).equals(SplitTier.tier1CleanLibrary);
          check(cluster.rationale).contains('Sub-component of the Bridge cone');
        }
        check(
          report.survivingDeclarations.map((d) => d.name).toList(),
        ).deepEquals(['Top']);
        check(report.estimatedRemainingLines).isLessOrEqual(110);
      },
    );

    test('Handles high-fan-out star topology (320+ leaf cones) in < 500 ms '
        'and preserves >= 1 surviving declaration when header overhead exceeds '
        'targetLines (#174)', () async {
      final file = File(p.join(tempDir.path, 'bench_paths_sim.dart'));
      final header = List.generate(450, (i) => '// header $i').join('\n');
      final leaves = List.generate(
        320,
        (i) =>
            'int leaf$i() {\n'
            '  final a = $i;\n'
            '  final b = a + 1;\n'
            '  return b;\n'
            '}',
      ).join('\n\n');
      final calls = List.generate(
        320,
        (i) => '  sum += leaf$i();',
      ).take(55).join('\n');
      final tailCalls = List.generate(
        320,
        (i) => 'leaf$i()',
      ).skip(55).join(' + ');
      file.writeAsStringSync('''
$header

int createPaths() {
  var sum = 0;
$calls
  return sum + $tailCalls;
}

$leaves
''');

      final absPath = p.canonicalize(file.absolute.path);
      final helper = AnalysisContextHelper(includedPaths: [absPath]);
      final unitResult = await helper.getRequiredResolvedUnit(absPath);

      const analyzer = FileSplitAnalyzer();
      final sw = Stopwatch()..start();
      final report = analyzer.analyzeResolvedUnit(
        unitResult,
        displayPath: file.path,
        targetLines: 400,
        minClusterLines: 30,
      );
      sw.stop();

      check(sw.elapsedMilliseconds).isLessThan(500);
      check(report.declarationCount).equals(321);
      check(report.clusters).isNotEmpty();
      check(report.survivingDeclarations).isNotEmpty();
      check(
        report.survivingDeclarations.map((d) => d.name).toSet(),
      ).contains('createPaths');
    });

    test(
      'Splits bridged root cone when header overhead exceeds targetLines '
      'while keeping the bridging root in survivingDeclarations (#174)',
      () async {
        final file = File(p.join(tempDir.path, 'bridged_root_sim.dart'));
        final header = List.generate(30, (i) => '// header $i').join('\n');
        final padA = List.generate(25, (i) => '  final a$i = $i;').join('\n');
        final padB = List.generate(25, (i) => '  final b$i = $i;').join('\n');
        file.writeAsStringSync('''
$header

class BaseTap {
$padA
}

class ExtraTap {
$padB
}

class MainTap extends BaseTap {
  final ExtraTap extra = ExtraTap();
}
''');

        final absPath = p.canonicalize(file.absolute.path);
        final helper = AnalysisContextHelper(includedPaths: [absPath]);
        final unitResult = await helper.getRequiredResolvedUnit(absPath);

        const analyzer = FileSplitAnalyzer();
        final report = analyzer.analyzeResolvedUnit(
          unitResult,
          displayPath: file.path,
          targetLines: 80,
          minClusterLines: 20,
        );

        check(report.totalLines).isGreaterThan(80);
        check(report.clusters).length.equals(1);
        check(
          report.clusters.single.declarations.map((d) => d.name).toList(),
        ).deepEquals(['ExtraTap']);
        check(
          report.survivingDeclarations.map((d) => d.name).toList(),
        ).deepEquals(['BaseTap', 'MainTap']);
        check(report.estimatedRemainingLines).isLessOrEqual(80);
      },
    );
  });
}
