import 'dart:io';
import 'dart:isolate';

import 'package:checks/checks.dart';
import 'package:cognitive_complexity/cognitive_complexity.dart';
import 'package:cognitive_complexity/src/shallow/cli.dart';
import 'package:test/scaffolding.dart';

// Resolved from the package URI, not the CWD: other test files in the same
// process change `Directory.current`.
final _fixtureDir = Isolate.resolvePackageUriSync(
  Uri.parse('package:cognitive_complexity/'),
)!.resolve('../test/fixtures/shallow_sibling_step/');

void main() {
  group('SIBLING_STEP', () {
    ShallowReport analyzeFixture(String name) => ShallowAnalyzer().analyzeCode(
      File.fromUri(_fixtureDir.resolve(name)).readAsStringSync(),
      filePath: 'lib/src/$name',
    );

    ShallowClassification classOf(ShallowReport report, String name) =>
        report.findings.singleWhere((f) => f.name == name).classification;

    // Helpers a blind review of the dogfood refactors (kevmoo/pubviz at
    // f50f9fb, kevmoo/scripts.dart at f97ecee) said should not have been
    // inlined because sibling steps stayed extracted.
    const reverts = {
      'pubviz_service.dart': [
        'Service._loadPackageGraphFile',
        'Service._loadPackageConfigFile',
      ],
      'pubviz_viz_root.dart': [
        'VizRoot._filterIgnored',
        'VizRoot._filterStandard',
        'VizRoot._filterIsolated',
      ],
      'scripts_process_inspector.dart': [
        'ProcFsProcessInspector._readProcEnviron',
      ],
      'scripts_kscripts_runner.dart': ['_reportStaleShim'],
      'scripts_github_cli.dart': ['_resolveLocalHeadSha'],
      'scripts_report_printer.dart': ['_printSection4ClosedAndAbandoned'],
    };

    // Helpers the same review said were good inlines.
    const keeps = {
      'scripts_gerrit_view.dart': '_getDefaultBranch',
      'scripts_graphql_utils.dart': '_buildGraphQLArgs',
      'scripts_dart_clean.dart': '_fetchPidAncestry',
      'scripts_github_queries.dart': '_resolveActiveReviewers',
    };

    for (final MapEntry(key: fixture, value: names) in reverts.entries) {
      for (final name in names) {
        test('reviewer-reverted $name is SIBLING_STEP', () {
          final report = analyzeFixture(fixture);
          final finding = report.findings.singleWhere((f) => f.name == name);
          check(
            finding.classification,
          ).equals(ShallowClassification.siblingStep);
          check(finding.headroomAfterInline).isGreaterThan(0);
          check(finding.siblingSteps).isNotEmpty();
        });
      }
    }

    for (final MapEntry(key: fixture, value: name) in keeps.entries) {
      test('reviewer-approved $name stays SAFE_INLINE', () {
        check(
          classOf(analyzeFixture(fixture), name),
        ).equals(ShallowClassification.safeInline);
      });
    }

    test('names the matching siblings', () {
      final report = analyzeFixture('scripts_process_inspector.dart');
      final finding = report.findings.singleWhere(
        (f) => f.name == 'ProcFsProcessInspector._readProcEnviron',
      );
      check(
        finding.siblingSteps,
      ).deepEquals(['_readProcCmdline', '_readProcCwd', '_readProcString']);
    });

    test('rule (a): one sibling sharing two leading tokens', () {
      const code = '''
void run(String p) {
  _readProcA(p);
  _readProcB(p, p);
}
void _readProcA(String p) { print(p); }
void _readProcB(String p, String q) {
  if (p == q) print(p);
  if (p != q) print(q);
  for (final c in p.split('')) {
    if (c == q) print(c);
  }
}
''';
      final report = ShallowAnalyzer().analyzeCode(code);
      check(
        classOf(report, '_readProcA'),
      ).equals(ShallowClassification.siblingStep);
    });

    test('rule (b): two siblings sharing only the verb, any arity', () {
      const code = '''
void run(String p) {
  _loadA(p);
  _loadB(p, 1);
  _loadC(p, 1, 2);
}
void _loadA(String p) { print(p); }
void _loadB(String p, int a) { print(p * a); }
void _loadC(String p, int a, int b) { print(p * (a + b)); }
''';
      final report = ShallowAnalyzer().analyzeCode(code);
      for (final name in ['_loadA', '_loadB', '_loadC']) {
        check(classOf(report, name)).equals(ShallowClassification.siblingStep);
      }
    });

    test('rule (c): one sibling sharing verb and arity; one-line '
        'pass-throughs and arity mismatches stay SAFE_INLINE', () {
      const code = '''
String alias(String p) => p;
void run(String p) {
  _emitHeader(p);
  _emitFooter(p);
  _emitAlias(p);
  _sendOne(p);
  _sendTwo(p, p);
}
void _emitHeader(String p) {
  print('header');
  print(p);
}
void _emitFooter(String p) {
  print(p);
  print('footer');
}
void _emitAlias(String p) => alias(p);
void _sendOne(String p) {
  print('one');
  print(p);
}
void _sendTwo(String p, String q) {
  print(p);
  print(q);
}
''';
      final report = ShallowAnalyzer().analyzeCode(code);
      // `_emit*` has three verb siblings, so rule (b) covers even the
      // one-line `_emitAlias`.
      check(
        classOf(report, '_emitAlias'),
      ).equals(ShallowClassification.siblingStep);
      check(
        classOf(report, '_sendOne'),
      ).equals(ShallowClassification.safeInline);
      check(
        classOf(report, '_sendTwo'),
      ).equals(ShallowClassification.safeInline);

      const passThrough = '''
String sniff(String p) => p;
void run(String p) {
  _getDefault(p);
  _getCurrent(p);
}
String _getDefault(String p) => sniff(p);
String _getCurrent(String p) {
  final v = p.trim();
  return v.isEmpty ? p : v;
}
''';
      final passReport = ShallowAnalyzer().analyzeCode(passThrough);
      check(
        classOf(passReport, '_getDefault'),
      ).equals(ShallowClassification.safeInline);
      check(
        classOf(passReport, '_getCurrent'),
      ).equals(ShallowClassification.siblingStep);
    });

    test('siblings must share the caller, file, and enclosing type', () {
      const code = '''
class A {
  void run(String p) {
    _writeA(p);
    B()._writeB(p);
  }
  void _writeA(String p) { print(p); }
}
class B {
  void _writeB(String p) { print(p); }
}
void other(String p) => _writeC(p);
void _writeC(String p) { print(p); }
''';
      final report = ShallowAnalyzer().analyzeCode(code);
      check(
        classOf(report, 'A._writeA'),
      ).equals(ShallowClassification.safeInline);
      check(
        classOf(report, '_writeC'),
      ).equals(ShallowClassification.safeInline);
    });

    test('SIBLING_STEP is not absorbed, not gated, and is reported in text '
        'and JSON', () async {
      // `run` scores 9. Helpers simulate in ascending delta order:
      // `_readProcX` (+3) is a sibling step of `_readProcY`; if it were
      // absorbed, `_formatY` (+4) would simulate 12 -> 16 instead of 9 -> 13.
      const code = '''
void run(int a, int b, int c, int d, int e, int f) {
  if (a > 0) {}
  if (b > 0) {}
  if (c > 0) {}
  if (d > 0) {}
  if (e > 0) {}
  if (f > 0) {}
  if (a > 1) {}
  if (b > 1) {}
  if (c > 1) {}
  _readProcX(a, b, c, d, e, f);
  _readProcY(a, b, c, d, e, f);
  _formatY(a, b, c, d, e, f);
}
void _readProcX(int a, int b, int c, int d, int e, int f) {
  if (a > 1) print(b);
  if (c > 2) print(d);
  if (e > 3) print(f);
}
void _readProcY(int a, int b, int c, int d, int e, int f) {
  if (a > 1) print(1);
  if (b > 2) print(2);
  if (c > 3) print(3);
  if (d > 3) print(3);
  if (e > 4) print(4);
  if (f > 5) print(5);
  if (a > 6) print(6);
}
void _formatY(int a, int b, int c, int d, int e, int f) {
  if (a > 1) print(b);
  if (c > 2) print(d);
  if (e > 3) print(f);
  if (a > 4) print(4);
}
''';
      final report = ShallowAnalyzer().analyzeCode(code);
      final byName = {for (final f in report.findings) f.name: f};
      final step = byName['_readProcX']!;
      check(step.classification).equals(ShallowClassification.siblingStep);
      check(step.inlinedCallerScore).equals(12);
      check(step.siblingSteps).deepEquals(['_readProcY']);
      final formatY = byName['_formatY']!;
      check(formatY.callerCumulativeBefore).equals(9);
      check(formatY.inlinedCallerScore).equals(13);
      check(formatY.classification).equals(ShallowClassification.safeInline);
      check(
        byName['_readProcY']!.classification,
      ).equals(ShallowClassification.loadBearing);
      check(byName['_readProcY']!.siblingSteps).isEmpty();

      check(report.siblingStepCount).equals(1);
      check(report.safeInlineCount).equals(1);
      final json = report.toJson();
      check(json['sibling_step_count']).equals(1);
      final jsonStep = (json['findings'] as List)
          .cast<Map<String, dynamic>>()
          .singleWhere((f) => f['name'] == '_readProcX');
      check(jsonStep['classification']).equals('SIBLING_STEP');
      check(jsonStep['sibling_steps'] as List).deepEquals(['_readProcY']);

      final text = report.formatText();
      check(text).contains('1 SIBLING_STEP with same-stem siblings kept');
      check(text).contains(
        'siblings=[_readProcY] stay extracted '
        '-> keep the sequence symmetric',
      );
      check(
        report.formatText(onlySafe: true),
      ).not((it) => it.contains('[SIBLING_STEP]'));

      final dir = Directory.systemTemp.createTempSync('sibling_step_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/steps.dart')
        ..writeAsStringSync(
          code.replaceAll('  _formatY(a, b, c, d, e, f);\n', ''),
        );
      final out = StringBuffer();
      final exitCode = await runShallowCli(
        ['--fail-on-safe-inline', file.path],
        out: out,
        err: StringBuffer(),
      );
      check(exitCode).equals(0);
      check(out.toString()).contains('[SIBLING_STEP]');
    });
  });
}
