import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:cognitive_complexity/cognitive_complexity.dart';
import 'package:cognitive_complexity/src/file_split/cli.dart' as file_split_cli;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Regression fixtures trimmed from public kevmoo/scripts.dart at `f97ecee`
/// (`lib/src/gh_view.dart`, `lib/src/gh_clean.dart`, and
/// `lib/src/gh_clean/github_queries.dart`), keeping the declaration shapes and
/// import graph that drove issue #182.
void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('file_split_naming_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  String pad(String prefix, int count) =>
      List.generate(count, (i) => '  static const $prefix$i = $i;').join('\n');

  File writeFile(String relativePath, String contents) =>
      File(p.join(tempDir.path, relativePath))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(contents);

  group('type-cluster naming and sibling types', () {
    late File ghView;

    setUp(() {
      // `renderCi` dominates the CI helpers and their types; `GhPr` dominates
      // the merge-state types. `MergeStateStatus` reads a private helper that
      // stays behind with `GhPr`, so it cannot follow its siblings.
      ghView = writeFile('gh_view.dart', '''
class GhViewException implements Exception {
  final String message;
  GhViewException(this.message);
}

extension type const ReviewDecision(String value) implements String {
  static const approved = ReviewDecision('APPROVED');
  static const changesRequested = ReviewDecision('CHANGES_REQUESTED');
  static const reviewRequired = ReviewDecision('REVIEW_REQUIRED');
${pad('r', 11)}
}

extension type const MergeableState(String value) implements String {
  static const mergeable = MergeableState('MERGEABLE');
  static const conflicting = MergeableState('CONFLICTING');
${pad('m', 3)}
}

extension type const MergeStateStatus(String value) implements String {
  static const clean = MergeStateStatus('CLEAN');
  static const blocked = MergeStateStatus('BLOCKED');
  bool get isClean => _normalize(value) == 'clean';
${pad('s', 2)}
}

extension type const CiStatus(String value) implements String {
  static const success = CiStatus('SUCCESS');
  static const failure = CiStatus('FAILURE');
  static const pending = CiStatus('PENDING');
${pad('c', 17)}
}

String _normalize(String raw) => raw.toLowerCase();

class GhPr {
  final MergeableState mergeable;
  final MergeStateStatus mergeStateStatus;
  GhPr(this.mergeable, this.mergeStateStatus);
  String get label => _normalize(mergeable);
${pad('g', 70)}
}

CiStatus extractCiStatus(Map<String, dynamic>? commits) {
  if (commits == null) throw GhViewException('no commits');
  final state = commits['state'];
  if (state == 'SUCCESS') return CiStatus.success;
  if (state == 'FAILURE') return CiStatus.failure;
  return CiStatus.pending;
}

String? extractCiDetail(Map<String, dynamic>? commits, ReviewDecision d) {
  if (commits == null) return null;
  final contexts = commits['contexts'] as List? ?? const [];
  final lines = <String>[];
  for (final ctx in contexts) {
    final name = (ctx as Map)['name'];
    final status = ctx['status'];
    if (status == 'FAILURE') {
      lines.add('\$name failed');
    } else if (status == 'ERROR') {
      lines.add('\$name errored');
    }
  }
${List.generate(12, (i) => '  final x$i = $i;').join('\n')}
  if (lines.isEmpty) return null;
  return '\$d: \${lines.join(', ')}';
}

String renderCi(Map<String, dynamic>? commits) {
  final status = extractCiStatus(commits);
  final detail = extractCiDetail(commits, ReviewDecision.approved);
  return '\$status \${detail ?? ''}';
}

void runGhView(Map<String, dynamic>? commits) {
  final pr = GhPr(MergeableState.mergeable, MergeStateStatus.clean);
  print(pr.label);
  print(renderCi(commits));
}
''');
    });

    test('names a type-heavy cut <stem>_models.dart and pulls leaf sibling '
        'types, noting siblings it cannot move', () async {
      const analyzer = FileSplitAnalyzer();
      final report = await analyzer.analyzeFile(
        ghView.path,
        targetLines: 120,
        minClusterLines: 40,
      );

      final cut = report.clusters.singleWhere(
        (c) => c.declarations.any((d) => d.name == 'CiStatus'),
      );
      // Premise: the dominant-public-declaration rule alone would name this
      // cut after `extractCiDetail`, which is longer than every type in it.
      final byName = {for (final d in cut.declarations) d.name: d};
      check(
        byName['extractCiDetail']!.lineCount,
      ).isGreaterThan(byName['CiStatus']!.lineCount);
      final names = cut.declarations.map((d) => d.name).toSet();
      for (final name in [
        'GhViewException',
        'ReviewDecision',
        'CiStatus',
        'extractCiDetail',
        // Pulled sibling: a leaf `extension type … (String)`.
        'MergeableState',
      ]) {
        check(names).contains(name);
      }
      check(cut.suggestedFileName).equals('gh_view_models.dart');
      check(cut.tier).equals(SplitTier.tier1CleanLibrary);

      final surviving = report.survivingDeclarations.map((d) => d.name);
      check(surviving).contains('MergeStateStatus');
      check(cut.notes).any(
        (it) => it
          ..contains('MergeableState')
          ..contains('kept with'),
      );
      check(cut.notes).any(
        (it) => it
          ..contains('MergeStateStatus')
          ..contains('left in gh_view.dart'),
      );

      final text = report.formatText();
      check(text).contains('Suggested File: gh_view_models.dart');
      check(text).contains('MergeStateStatus');
      final json = cut.toJson();
      check(json['notes']).isA<List<dynamic>>().length.equals(2);
      final reprs = {
        for (final d in cut.declarations)
          if (d.representationType != null) d.name: d.representationType,
      };
      check(reprs['CiStatus']).equals('String');
    });

    test('keeps naming a cut after its dominant function when types are '
        'below half of its lines', () async {
      final file = writeFile('runner.dart', '''
enum Mode { fast, slow }

enum Level { low, high }

int helperOne(Mode m) {
${List.generate(30, (i) => '  final h$i = $i;').join('\n')}
  return m.index;
}

int buildPlan(Level l) {
  final x = helperOne(Mode.fast);
${List.generate(30, (i) => '  final b$i = $i;').join('\n')}
  return x + l.index;
}

void main() {
  print(buildPlan(Level.low));
${List.generate(45, (i) => '  final m$i = $i;').join('\n')}
}
''');
      const analyzer = FileSplitAnalyzer();
      final report = await analyzer.analyzeFile(
        file.path,
        targetLines: 60,
        minClusterLines: 20,
      );
      final cut = report.clusters.singleWhere(
        (c) => c.declarations.any((d) => d.name == 'buildPlan'),
      );
      check(cut.suggestedFileName).equals('build_plan.dart');
    });
  });

  group('inherited import cycle warning', () {
    String queries(String importLine) =>
        '''
$importLine

class LandedPr {
  final int number;
  LandedPr(this.number);
${pad('l', 20)}
}

Future<List<LandedPr>> fetchLandedPrs(GhCleanOptions options) async {
  final prs = <LandedPr>[];
  for (var i = 0; i < options.limit; i++) {
    prs.add(LandedPr(i));
  }
${List.generate(25, (i) => '  final f$i = $i;').join('\n')}
  return prs;
}

Future<void> runQueries(GhCleanOptions options) async {
  final prs = await fetchLandedPrs(options);
  print(prs.length);
${List.generate(40, (i) => '  final q$i = $i;').join('\n')}
}
''';

    const options = '''
class GhCleanOptions {
  final int limit;
  const GhCleanOptions(this.limit);
}
''';

    Future<SplitCluster> analyzeQueries(String path) async {
      const analyzer = FileSplitAnalyzer();
      final report = await analyzer.analyzeFile(
        path,
        targetLines: 60,
        minClusterLines: 20,
      );
      return report.clusters.singleWhere(
        (c) => c.declarations.any((d) => d.name == 'fetchLandedPrs'),
      );
    }

    test('warns when a copied import re-exports the source file', () async {
      writeFile('gh_clean.dart', '''
export 'gh_clean/github_queries.dart';

$options''');
      final source = writeFile(
        'gh_clean/github_queries.dart',
        queries("import '../gh_clean.dart';"),
      );

      final cut = await analyzeQueries(source.path);
      check(cut.requiredImports).deepEquals(["import '../gh_clean.dart';"]);
      check(cut.warnings).deepEquals([
        "cut imports '../gh_clean.dart', which re-exports "
            'github_queries.dart (inherited import cycle)',
      ]);

      final out = StringBuffer();
      final code = await file_split_cli.runFileSplitCli([
        '--format',
        'json',
        '--target-lines',
        '60',
        '--min-cluster-lines',
        '20',
        source.path,
      ], out: out);
      check(code).equals(0);
      final report =
          (jsonDecode(out.toString()) as List).single as Map<String, dynamic>;
      final jsonCut = (report['clusters'] as List)
          .cast<Map<String, dynamic>>()
          .singleWhere((c) => (c['warnings'] as List?)?.isNotEmpty ?? false);
      check(
        jsonCut['warnings'] as List,
      ).deepEquals(cut.warnings.cast<Object?>());

      final textOut = StringBuffer();
      await file_split_cli.runFileSplitCli([
        '--target-lines',
        '60',
        '--min-cluster-lines',
        '20',
        source.path,
      ], out: textOut);
      check(textOut.toString())
        ..contains("Warning: cut imports '../gh_clean.dart', which re-exports")
        ..contains('1 inherited import cycle warning(s)');
    });

    test('warns through one re-export hop that imports the source', () async {
      writeFile('gh_clean.dart', '''
export 'hub.dart';

$options''');
      writeFile('hub.dart', '''
import 'gh_clean/github_queries.dart';

void touch() => print(runQueries);
''');
      final source = writeFile(
        'gh_clean/github_queries.dart',
        queries("import '../gh_clean.dart';"),
      );

      final cut = await analyzeQueries(source.path);
      check(cut.warnings).deepEquals([
        "cut imports '../gh_clean.dart', which re-exports hub.dart, which "
            'imports github_queries.dart (inherited import cycle)',
      ]);
    });

    test('does not warn when the copied import is unrelated', () async {
      writeFile('gh_clean_options.dart', options);
      writeFile('gh_clean.dart', "export 'gh_clean/github_queries.dart';\n");
      final source = writeFile(
        'gh_clean/github_queries.dart',
        queries("import '../gh_clean_options.dart';"),
      );

      final cut = await analyzeQueries(source.path);
      check(
        cut.requiredImports,
      ).deepEquals(["import '../gh_clean_options.dart';"]);
      check(cut.warnings).isEmpty();
      check(cut.toJson().containsKey('warnings')).isFalse();
    });
  });
}
