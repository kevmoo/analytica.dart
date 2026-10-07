import 'dart:convert';
import 'dart:io';

import 'package:analytica/testing.dart';
import 'package:checks/checks.dart';
import 'package:cognitive_complexity/cognitive_complexity.dart';
import 'package:cognitive_complexity/src/shallow/cli.dart';
import 'package:test/scaffolding.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;
import 'package:test_process/test_process.dart';

void main() {
  group('ShallowAnalyzer (in-memory)', () {
    test(
      'Flags HIGH_ARITY and MICRO_HELPER single-caller helpers and simulates '
      'exact nesting-aware caller CC',
      () {
        const code = '''
class OrderProcessor {
  void process(int a, int b, int c, int d, int e) {
    if (a > 0) {
      for (var i = 0; i < b; i++) {
        _handleItem(a, b, c, d, e, i);
      }
    }
  }

  void _handleItem(int a, int b, int c, int d, int e, int i) {
    if (c > d) {
      print(a + b + c + d + e + i);
    }
  }
}
''';
        final analyzer = ShallowAnalyzer();
        final report = analyzer.analyzeCode(
          code,
          filePath: 'lib/src/order.dart',
        );

        check(report.declarationsScanned).equals(2);
        check(report.findings.length).equals(1);
        final finding = report.findings.single;
        check(finding.name).equals('OrderProcessor._handleItem');
        check(finding.parameterCount).equals(6);
        check(finding.score).equals(1);
        check(finding.callerName).equals('OrderProcessor.process');
        check(finding.callNestingDepth).equals(2);
        // Caller score before inline: if (1) + for (2) = 3.
        // Callee has an `if` at root depth 0 (score 1), which at call depth 2
        // adds 1 + 2 = 3 to the caller, yielding 3 + 3 = 6 <= 15 (SAFE_INLINE).
        check(finding.callerCumulativeBefore).equals(3);
        check(finding.inlinedDeltaScore).equals(3);
        check(finding.inlinedCallerScore).equals(6);
        check(finding.classification).equals(ShallowClassification.safeInline);
        check(
          finding.reasons.any((r) => r.startsWith('HIGH_ARITY(6 params)')),
        ).isTrue();
      },
    );

    test(
      'Classifies FLATTEN_AND_INLINE and LOAD_BEARING when inlined caller CC '
      'exceeds threshold',
      () {
        const code = '''
void callerWithModerateCc(int a, int b, int c, int d, int e) {
  if (a > 0) {
    if (b > 0) {
      if (c > 0) {
        if (d > 0) {
          _wideHelper(a, b, c, d, e);
        }
      }
    }
  }
}

void _wideHelper(int a, int b, int c, int d, int e) {
  if (a == b) {
    if (c == d) {
      print(e);
    }
  }
}
''';
        final analyzer = ShallowAnalyzer(maxCallerScore: 15);
        final report = analyzer.analyzeCode(code);

        check(report.findings.length).equals(1);
        final finding = report.findings.single;
        // Caller CC: 1 + 2 + 3 + 4 = 10.
        // Call at depth 4: _wideHelper has outer if (5) + inner if (6) = 11.
        // Inlined caller CC = 10 + 11 = 21 -> FLATTEN_AND_INLINE (16..22).
        check(finding.callerCumulativeBefore).equals(10);
        check(finding.inlinedDeltaScore).equals(11);
        check(finding.inlinedCallerScore).equals(21);
        check(
          finding.classification,
        ).equals(ShallowClassification.flattenAndInline);

        final strictAnalyzer = ShallowAnalyzer(maxCallerScore: 10);
        final strictReport = strictAnalyzer.analyzeCode(code);
        check(
          strictReport.findings.single.classification,
        ).equals(ShallowClassification.loadBearing);

        // Helpers called at depth=0 (or with intrinsic CC >= 5) that push the
        // caller above maxCallerScore have no call-site nesting inflation to
        // flatten away, so they must be classified as LOAD_BEARING even when
        // inlinedCallerScore <= maxCallerScore + 7.
        const depthZeroCode = '''
void rootCaller(int a, int b, int c, int d, int e) {
  if (a > 0) {
    if (b > 0) {
      if (c > 0) {
        if (d > 0) {
          print(e);
        }
      }
    }
  }
  _depthZeroHelper(a, b, c, d, e);
}

void _depthZeroHelper(int a, int b, int c, int d, int e) {
  if (a == b) {
    if (c == d) {
      if (b == c) {
        print(e);
      }
    }
  }
}
''';
        final depthZeroReport = analyzer.analyzeCode(depthZeroCode);
        check(depthZeroReport.findings.length).equals(1);
        final depthZeroFinding = depthZeroReport.findings.single;
        check(depthZeroFinding.callNestingDepth).equals(0);
        check(depthZeroFinding.score).equals(6);
        check(depthZeroFinding.inlinedCallerScore).equals(16);
        check(
          depthZeroFinding.classification,
        ).equals(ShallowClassification.loadBearing);
      },
    );

    test('Exempts multi-caller helpers, tear-offs (including qualified and '
        'named-arg tear-offs), cross-class public methods, overrides, build '
        'methods, and ignored declarations', () {
      const code = '''
class ShortcutManager {
  final List<String> shortcuts = [];

  void registerAll(List<String> items) {
    shortcuts.addAll(items);
  }
}

class MyWidget {
  void run(List<int> items, ShortcutManager manager) {
    manager.registerAll(['ctrl+k']);
    _reused(1, 2);
    _reused(3, 4);
    final mapped = items.map(_tornOff).toList();
    _calledAndTornOffViaThis(1);
    final fn1 = this._calledAndTornOffViaThis;
    _calledAndTornOffViaStatic(1);
    final fn2 = MyWidget._calledAndTornOffViaStatic;
    _calledAndTornOffViaNamedArg(1);
    _acceptCallback(cb: _tornOff);
    _acceptCallback(cb: this._calledAndTornOffViaNamedArg);
    _ignoredHelper(1, 2, 3, 4, 5);
    print('\$mapped \$fn1 \$fn2');
  }

  void _acceptCallback({required int Function(int) cb}) {
    cb(1);
    cb(2);
  }

  int _reused(int a, int b) => a + b;

  int _tornOff(int x) => x * 2;

  int _calledAndTornOffViaThis(int x) => x + 1;

  static int _calledAndTornOffViaStatic(int x) => x + 2;

  int _calledAndTornOffViaNamedArg(int x) => x + 3;

  // cognitive_complexity:ignore
  void _ignoredHelper(int a, int b, int c, int d, int e) {
    print(a + b + c + d + e);
  }

  @override
  String toString() => 'MyWidget';
}
''';
      final report = ShallowAnalyzer().analyzeCode(code);
      check(report.findings).isEmpty();
    });
  });

  group('ShallowAnalyzer & CLI (filesystem)', () {
    final dartExe = Platform.resolvedExecutable;
    late String binPath;

    setUpAll(() async {
      binPath = await resolvePackageExecutable(
        'package:cognitive_complexity/cognitive_complexity.dart',
        'shallow',
      );
    });

    test(
      'Exempts public API exports, conditional import targets, and helpers '
      'referenced by test/ files without masking private lib/ helpers',
      () async {
        await d.dir('pkg', [
          d.file('pubspec.yaml', 'name: sample_pkg\n'),
          d.dir('lib', [
            d.file('sample_pkg.dart', '''
export 'src/exported_service.dart' show publicExportedFn;
'''),
            d.dir('src', [
              d.file('exported_service.dart', '''
import 'stub.dart' if (dart.library.js_interop) 'web.dart';

int publicExportedFn(int a, int b, int c, int d, int e) =>
    a + b + c + d + e + platformValue(a) + testedInternalFn(b) + _shallowHelper(a, b, c, d, e);

int testedInternalFn(int x) => x + 1;

int _shallowHelper(int a, int b, int c, int d, int e) => a + b + c + d + e;
'''),
              d.file('stub.dart', '''
int platformValue(int x) => x;
'''),
              d.file('web.dart', '''
int platformValue(int x) => x * 2;
'''),
            ]),
          ]),
          d.dir('test', [
            d.file('service_test.dart', '''
import 'package:sample_pkg/src/exported_service.dart';

void _shallowHelper() {}

void main() {
  testedInternalFn(42);
  _shallowHelper();
}
'''),
          ]),
        ]).create();

        final prevCurrent = Directory.current;
        final out = StringBuffer();
        final err = StringBuffer();
        late final int exitCode;
        try {
          Directory.current = '${d.sandbox}/pkg';
          exitCode = await runShallowCli(
            ['--format=json', '${d.sandbox}/pkg/lib'],
            out: out,
            err: err,
          );
        } finally {
          Directory.current = prevCurrent;
        }

        check(exitCode).equals(0);
        final json = jsonDecode(out.toString()) as Map<String, dynamic>;
        final findings = json['findings'] as List<dynamic>;
        // Only `_shallowHelper` in `lib/src/exported_service.dart` should be
        // flagged; `publicExportedFn` is exported, `platformValue` is a
        // conditional import target, `testedInternalFn` is called from
        // `test/service_test.dart`, and the private `_shallowHelper` in
        // `test/service_test.dart` must not mask `lib/`'s `_shallowHelper`.
        check(findings.length).equals(1);
        final single = findings.single as Map<String, dynamic>;
        check(single['name']).equals('_shallowHelper');
        check(single['classification']).equals('SAFE_INLINE');
      },
    );

    test('exempts cross-file single-caller functions that reference '
        'file-private declarations', () async {
      await d.dir('facade_pkg', [
        d.file('pubspec.yaml', 'name: facade_pkg\n'),
        d.dir('lib', [
          d.dir('src', [
            d.file('topology.dart', '''
List<int> computeScc(List<int> nodes, Map<int, List<int>> edges) {
  final state = _TarjanState(nodes);
  return _runTarjan(state, edges);
}

class _TarjanState {
  final List<int> nodes;
  _TarjanState(this.nodes);
}

List<int> _runTarjan(_TarjanState state, Map<int, List<int>> edges) {
  if (edges.isEmpty) return state.nodes;
  return [for (final n in state.nodes) if (edges.containsKey(n)) n];
}

int leafCrossFileHelper(int a, int b, int c) {
  return a + b + c;
}
'''),
            d.file('planner.dart', '''
import 'topology.dart';

int planSplits(List<int> nodes, Map<int, List<int>> edges) {
  final sccs = computeScc(nodes, edges);
  return leafCrossFileHelper(sccs.length, nodes.length, edges.length);
}
'''),
          ]),
        ]),
      ]).create();

      final analyzer = ShallowAnalyzer();
      final report = analyzer.analyzePath('${d.sandbox}/facade_pkg/lib');

      final names = report.findings.map((f) => f.name).toList();
      check(names).contains('leafCrossFileHelper');
      check(names.contains('computeScc')).isFalse();
    });

    test(
      'enforces cumulative caller CC budget and bottom-up chain propagation',
      () {
        const code = '''
void printReport(int a, int b, int c, int d, int e, int f, int g) {
  if (a > 0 && b > 0 && c > 0) {
    if (d > 0) {
      _reportDelta(a, b, c, d, e, f, g);
      _reportRegular(a, b, c, d, e, f);
    }
  }
}

void _reportDelta(int a, int b, int c, int d, int e, int f, int g) {
  if (a > 0 && b > 0) {
    if (c > 0) {
      _stepA(a, b, c, d, e, f, g, a);
    }
  }
  _stepB(a, b, c, d, e, f, g);
  _stepC(a, b, c, d, e, f);
  _stepD(a, b, c, d, e);
}

void _reportRegular(int a, int b, int c, int d, int e, int f) {
  if (a > 0) {
    if (b > 0) {
      print(c + d + e + f);
    }
  }
}

void _stepA(int a, int b, int c, int d, int e, int f, int g, int h) {
  if (a > 0 && b > 0) {
    if (c > 0) {
      print(d + e + f + g + h);
    }
  }
}

void _stepB(int a, int b, int c, int d, int e, int f, int g) {
  if (a > 0 && b > 0) {
    print(c + d + e + f + g);
  }
}

void _stepC(int a, int b, int c, int d, int e, int f) {
  if (a > 0 && b > 0) {
    print(c + d + e + f);
  }
}

void _stepD(int a, int b, int c, int d, int e) {
  if (a > 0 && b > 0) {
    print(c + d + e);
  }
}
''';
        final analyzer = ShallowAnalyzer();
        final report = analyzer.analyzeCode(code);

        final byName = {for (final f in report.findings) f.name: f};
        check(
          byName['_stepB']!.classification,
        ).equals(ShallowClassification.safeInline);
        check(
          byName['_stepC']!.classification,
        ).equals(ShallowClassification.safeInline);
        check(
          byName['_stepD']!.classification,
        ).equals(ShallowClassification.safeInline);
        check(
          byName['_stepA']!.classification,
        ).equals(ShallowClassification.flattenAndInline);
        check(
          byName['_reportDelta']!.classification,
        ).equals(ShallowClassification.loadBearing);
        check(
          byName['_reportRegular']!.classification,
        ).equals(ShallowClassification.safeInline);
      },
    );

    test('caller_base_score stays at the static caller score while '
        'caller_cumulative_before accumulates across sibling helpers', () {
      // `_caller` scores 3 statically (if +1, nested if +2). Each helper's
      // `if` inlines at depth 2 for +3, so the cumulative baseline walks
      // 3 -> 6 -> 9 while the base must stay 3 for every finding.
      const code = '''
void _caller(int a, int b, int c, int d, int e, int f) {
  if (a > 0) {
    if (b > 0) {
      _h1(a, b, c, d, e, f);
      _h2(a, b, c, d, e, f);
      _h3(a, b, c, d, e, f);
    }
  }
}
void _h1(int a, int b, int c, int d, int e, int f) { if (true) print(1); }
void _h2(int a, int b, int c, int d, int e, int f) { if (true) print(2); }
void _h3(int a, int b, int c, int d, int e, int f) { if (true) print(3); }
''';
      final analyzer = ShallowAnalyzer();
      final report = analyzer.analyzeCode(code);

      final byName = {for (final f in report.findings) f.name: f};
      check(byName.keys).unorderedEquals(['_h1', '_h2', '_h3']);
      for (final f in byName.values) {
        check(f.callerBaseScore).equals(3);
        check(
          f.inlinedCallerScore,
        ).equals(f.callerCumulativeBefore + f.inlinedDeltaScore);
        check(f.classification).equals(ShallowClassification.safeInline);
      }
      check(byName['_h1']!.callerCumulativeBefore).equals(3);
      check(byName['_h2']!.callerCumulativeBefore).equals(6);
      check(byName['_h3']!.callerCumulativeBefore).equals(9);

      final h2Json = byName['_h2']!.toJson();
      check(h2Json['caller_base_score']).equals(3);
      check(h2Json['caller_cumulative_before']).equals(6);
      check(h2Json.containsKey('caller_score')).isFalse();
      check(h2Json['inlined_caller_score']).equals(9);

      final text = report.formatText();
      check(text).contains('Caller CC: 3 -> 6 after inline (+3)');
      check(text).contains('Caller CC: 6 (base 3) -> 9 after inline (+3)');
      check(text).contains('Caller CC: 9 (base 3) -> 12 after inline (+3)');

      // The isolated score is base + own delta regardless of sibling order,
      // while headroom tracks the cumulative result.
      for (final f in byName.values) {
        check(f.inlinedCallerScoreIsolated).equals(6);
        check(f.headroomAfterInline).equals(15 - f.inlinedCallerScore);
      }
      check(h2Json['inlined_caller_score_isolated']).equals(6);
      check(h2Json['headroom_after_inline']).equals(6);
      check(h2Json['caller_zone']).equals('other');
      check(text).contains('Caller CC: 3 -> 6 after inline (+3) | Est.');
      check(text).contains('(+3) [isolated 3 -> 6, headroom 6] | Est.');
      check(text).contains('(+3) [isolated 3 -> 6, headroom 3] | Est.');
    });

    test('headroom_after_inline is 0 at exactly maxCallerScore and negative '
        'above it', () {
      // `_edge` scores 6 (nested ifs) + 5 (flat ifs) = 11; `_h` adds 1 + 3
      // (call depth 3) = 4, landing exactly on 15.
      const code = '''
void _edge(int a, int b, int c, int d, int e, int f) {
  if (a > 0) {
    if (b > 0) {
      if (c > 0) {
        _h(a, b, c, d, e, f);
      }
    }
  }
  if (d > 0) {}
  if (e > 0) {}
  if (f > 0) {}
  if (a > 1) {}
  if (b > 1) {}
}
void _h(int a, int b, int c, int d, int e, int f) { if (true) print(1); }
''';
      final atCeilingReport = ShallowAnalyzer().analyzeCode(code);
      final atCeiling = atCeilingReport.findings.single;
      check(atCeiling.callerBaseScore).equals(11);
      check(atCeiling.inlinedCallerScore).equals(15);
      check(atCeiling.inlinedCallerScoreIsolated).equals(15);
      check(atCeiling.headroomAfterInline).equals(0);
      check(
        atCeiling.classification,
      ).equals(ShallowClassification.zeroHeadroom);
      check(atCeilingReport.safeInlineCount).equals(0);
      check(atCeilingReport.zeroHeadroomCount).equals(1);
      check(atCeilingReport.toJson()['zero_headroom_count']).equals(1);
      check(
        atCeilingReport.formatText(),
      ).contains('1 ZERO_HEADROOM landing exactly on 15');

      final belowCeiling = ShallowAnalyzer(
        maxCallerScore: 16,
      ).analyzeCode(code).findings.single;
      check(belowCeiling.headroomAfterInline).equals(1);
      check(
        belowCeiling.classification,
      ).equals(ShallowClassification.safeInline);

      final overCeiling = ShallowAnalyzer(
        maxCallerScore: 14,
      ).analyzeCode(code).findings.single;
      check(overCeiling.headroomAfterInline).equals(-1);
      check(
        overCeiling.classification,
      ).equals(ShallowClassification.flattenAndInline);
    });

    test('ZERO_HEADROOM helpers are not absorbed into the caller cumulative '
        'score and do not trip --fail-on-safe-inline', () async {
      // `_edge` scores 11. Candidates simulate in ascending delta order:
      // `_h1` (+4) lands exactly on 15 (ZERO_HEADROOM) and must not raise
      // the cumulative base, so `_h2` (+6 at depth 1) simulates 11 -> 17,
      // not 15 -> 21.
      const code = '''
void _edge(int a, int b, int c, int d, int e, int f) {
  if (a > 0) {
    if (b > 0) {
      if (c > 0) {
        _h1(a, b, c, d, e, f);
      }
    }
  }
  if (d > 0) {}
  if (e > 0) {}
  if (f > 0) {}
  if (a > 1) {}
  if (b > 1) {
    _h2(a, b, c, d, e, f);
  }
}
void _h1(int a, int b, int c, int d, int e, int f) { if (true) print(1); }
void _h2(int a, int b, int c, int d, int e, int f) {
  if (a > 2) print(2);
  if (b > 2) print(2);
  if (c > 2) print(2);
}
''';
      final report = ShallowAnalyzer().analyzeCode(code);
      final byName = {for (final f in report.findings) f.name: f};
      final h1 = byName['_h1']!;
      final h2 = byName['_h2']!;
      check(h1.classification).equals(ShallowClassification.zeroHeadroom);
      check(h1.inlinedCallerScore).equals(15);
      check(h2.callerCumulativeBefore).equals(11);
      check(h2.inlinedCallerScore).equals(17);
      check(h2.classification).equals(ShallowClassification.flattenAndInline);

      final dir = Directory.systemTemp.createTempSync('zero_headroom_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File(
        '${dir.path}/ceiling.dart',
      )..writeAsStringSync(code.replaceAll('    _h2(a, b, c, d, e, f);\n', ''));
      final out = StringBuffer();
      final code0 = await runShallowCli(
        ['--fail-on-safe-inline', file.path],
        out: out,
        err: StringBuffer(),
      );
      check(code0).equals(0);
      check(out.toString()).contains('[ZERO_HEADROOM]');
    });

    test('MICRO_HELPER catches formatter-wrapped helpers with <= 2 statements '
        'but not 3-statement helpers of the same length', () {
      const code = '''
void _caller(int a, int b) {
  if (a > 0) {
    _wrapped(a);
    _threeStatements(b);
  }
}

void _wrapped(int value) {
  final label = value.toString() +
      '-' +
      value.toRadixString(16) +
      '-' +
      value.toRadixString(2);
  print(label);
}

void _threeStatements(int value) {
  final a = value.toString();
  final b = value.toRadixString(16) +
      '-' +
      value.toRadixString(2) +
      '-';
  print(a + b);
}
''';
      final report = ShallowAnalyzer().analyzeCode(code);
      final finding = report.findings.single;
      check(finding.name).equals('_wrapped');
      check(finding.bodyLines).equals(8);
      check(finding.statementCount).equals(2);
      check(finding.score).equals(0);
      check(
        finding.reasons,
      ).deepEquals(['MICRO_HELPER(8 bodyL, 2 stmt, CC=0)']);
      check(finding.toJson()['statement_count']).equals(2);
    });

    test('HIGH_ARITY counts record-typed parameters by their field count', () {
      const code = '''
void _caller(int a, int b, int c, int d, int e, int f) {
  if (a > 0) {
    _packed(a, b, c, (d, e, name: 'x'));
    _packedOptional(a, b, c, (d, e));
    _plain(a, b, c, d);
  }
}

void _packed(int a, int b, int c, (int, int, {String name}) rec) {
  if (a > b) print(c + rec.\$1 + rec.\$2 + rec.name.length);
}

void _packedOptional(int a, int b, int c, [(int, int)? rec]) {
  if (a > b) print(c + (rec?.\$1 ?? 0));
}

void _plain(int a, int b, int c, int d) {
  if (a > b) print(c + d);
}
''';
      final report = ShallowAnalyzer().analyzeCode(code);
      final byName = {for (final f in report.findings) f.name: f};
      check(
        byName.keys,
      ).unorderedEquals(['_packed', '_packedOptional', '_plain']);

      final packed = byName['_packed']!;
      check(packed.parameterCount).equals(4);
      check(packed.effectiveParameterCount).equals(6);
      check(packed.reasons).contains('HIGH_ARITY(4 params, 6 effective)');
      check(packed.toJson()['effective_parameter_count']).equals(6);

      final optional = byName['_packedOptional']!;
      check(optional.effectiveParameterCount).equals(5);
      check(optional.reasons).contains('HIGH_ARITY(4 params, 5 effective)');

      final plain = byName['_plain']!;
      check(plain.effectiveParameterCount).equals(4);
      check(plain.reasons.any((r) => r.startsWith('HIGH_ARITY'))).isFalse();
    });

    test('suppresses CROSS_FILE_SINGLE_CALLER for lib/ helpers whose only '
        'caller is in bin/, but keeps it for lib/ -> lib/ edges', () async {
      // `wideHelper` has 4 statements and CC 3, so it is neither MICRO_HELPER
      // nor HIGH_ARITY nor SIG_HEAVY: only CROSS_FILE_SINGLE_CALLER can flag
      // it. `tinyHelper` is a MICRO_HELPER regardless of caller zone.
      const helpers = '''
int wideHelper(int a, int b, int c) {
  var total = a;
  if (b > 0) total += b;
  if (c > 0) total += c;
  if (a < 0) total = -total;
  return total;
}

int tinyHelper(int a, int b, int c) => a + b + c;
''';
      await d.dir('zone_pkg', [
        d.file('pubspec.yaml', 'name: zone_pkg\n'),
        d.dir('lib', [
          d.dir('src', [d.file('helpers.dart', helpers)]),
        ]),
        d.dir('bin', [
          d.file('tool.dart', '''
import 'package:zone_pkg/src/helpers.dart';

void main(List<String> args) {
  _runCommand(args.length);
}

void _runCommand(int n) {
  if (n > 0) {
    print(wideHelper(n, n, n));
    print(tinyHelper(n, n, n));
  }
}
'''),
        ]),
      ]).create();
      await d.dir('lib_pkg', [
        d.file('pubspec.yaml', 'name: lib_pkg\n'),
        d.dir('lib', [
          d.dir('src', [
            d.file('helpers.dart', helpers),
            d.file('service.dart', '''
import 'helpers.dart';

void _runService(int n) {
  if (n > 0) {
    print(wideHelper(n, n, n));
    print(tinyHelper(n, n, n));
  }
}
'''),
          ]),
        ]),
      ]).create();

      final analyzer = ShallowAnalyzer();
      final fromBin = analyzer.analyzePath('${d.sandbox}/zone_pkg/lib');
      final binByName = {for (final f in fromBin.findings) f.name: f};
      check(binByName.keys).unorderedEquals(['tinyHelper']);
      final tinyFromBin = binByName['tinyHelper']!;
      check(tinyFromBin.callerZone).equals('bin');
      check(tinyFromBin.callerName).equals('_runCommand');
      check(
        tinyFromBin.reasons.any((r) => r.startsWith('CROSS_FILE')),
      ).isFalse();
      check(tinyFromBin.toJson()['caller_zone']).equals('bin');

      final fromLib = analyzer.analyzePath('${d.sandbox}/lib_pkg/lib');
      final libByName = {for (final f in fromLib.findings) f.name: f};
      check(libByName.keys).unorderedEquals(['wideHelper', 'tinyHelper']);
      check(libByName['wideHelper']!.callerZone).equals('lib');
      check(
        libByName['wideHelper']!.reasons,
      ).deepEquals(['CROSS_FILE_SINGLE_CALLER(from service.dart)']);
    });

    test('drops CROSS_FILE_SINGLE_CALLER for lib/ helpers called once from '
        'tool/, example/, web/, or benchmark/, and ignores helpers with a '
        'test/ caller', () async {
      String helper(String name) =>
          'int $name(int a, int b, int c) => a + b + c;';
      String caller(String name) =>
          '''
import 'package:zones_pkg/src/helpers.dart';

void main() {
  print($name(1, 2, 3));
}
''';
      await d.dir('zones_pkg', [
        d.file('pubspec.yaml', 'name: zones_pkg\n'),
        d.dir('lib', [
          d.dir('src', [
            d.file(
              'helpers.dart',
              [
                helper('toolHelper'),
                helper('exampleHelper'),
                helper('webHelper'),
                helper('benchHelper'),
                helper('mixedHelper'),
              ].join('\n'),
            ),
            d.file('service.dart', '''
import 'helpers.dart';

void _runService(int n) {
  if (n > 0) print(mixedHelper(n, n, n));
}
'''),
          ]),
        ]),
        d.dir('tool', [d.file('t.dart', caller('toolHelper'))]),
        d.dir('example', [d.file('ex.dart', caller('exampleHelper'))]),
        d.dir('web', [d.file('main.dart', caller('webHelper'))]),
        d.dir('benchmark', [d.file('b.dart', caller('benchHelper'))]),
        d.dir('test', [d.file('mixed_test.dart', caller('mixedHelper'))]),
      ]).create();

      final report = ShallowAnalyzer().analyzePath(
        '${d.sandbox}/zones_pkg/lib',
      );
      final byName = {for (final f in report.findings) f.name: f};
      check(byName.keys).unorderedEquals([
        'toolHelper',
        'exampleHelper',
        'webHelper',
        'benchHelper',
      ]);
      const zones = {
        'toolHelper': 'tool',
        'exampleHelper': 'example',
        'webHelper': 'web',
        'benchHelper': 'benchmark',
      };
      for (final MapEntry(key: name, value: zone) in zones.entries) {
        final finding = byName[name]!;
        check(finding.callerZone).equals(zone);
        check(finding.toJson()['caller_zone']).equals(zone);
        check(finding.callerName).equals('main');
        check(finding.reasons.any((r) => r.startsWith('CROSS_FILE'))).isFalse();
        check(
          finding.reasons.any((r) => r.startsWith('MICRO_HELPER')),
        ).isTrue();
      }
    });

    test('reports shared_param_signature_with for siblings sharing >= 4 '
        'parameter names', () {
      const code = '''
void _runPublish(List<String> parts, bool viaHttp) {
  if (viaHttp) {
    _publishViaHttp(parts[0], parts[1], parts[2], parts[3], parts[4],
        parts[5], parts[6], parts[7], 3);
  } else {
    _publishToDatastore(parts[0], parts[1], parts[2], parts[3], parts[4],
        parts[5], parts[6], parts[7], 'ns');
  }
}

void _publishViaHttp(String host, String path, String token, String body,
    String owner, String repo, String branch, String label, int retries) {
  print([host, path, token, body, owner, repo, branch, label, retries]);
}

void _publishToDatastore(String host, String path, String token, String body,
    String owner, String repo, String branch, String label, String ns) {
  print([host, path, token, body, owner, repo, branch, label, ns]);
}
''';
      final report = ShallowAnalyzer().analyzeCode(code);
      final byName = {for (final f in report.findings) f.name: f};
      check(
        byName.keys,
      ).unorderedEquals(['_publishViaHttp', '_publishToDatastore']);

      final http = byName['_publishViaHttp']!;
      check(http.sharedParamSignatureWith).equals('_publishToDatastore');
      check(http.sharedParamCount).equals(8);
      check(http.paramsSubsetOfExistingType).isNull();
      final json = http.toJson();
      check(json['shared_param_signature_with']).equals('_publishToDatastore');
      check(json['shared_param_count']).equals(8);
      check(json['params_subset_of_existing_type']).isNull();

      check(
        byName['_publishToDatastore']!.sharedParamSignatureWith,
      ).equals('_publishViaHttp');
      check(report.formatText()).contains(
        '  Facts: shares 8 params with _publishToDatastore '
        '-> prefer a shared parameter record',
      );
    });

    test('reports params_subset_of_existing_type from same-file instance '
        'fields, preferring the enclosing type', () {
      const code = '''
class _Unrelated {
  final int rows;
  final int title;
  final int sortKey;
  final int ascending;
  final int filter;
  final int extra;
  _Unrelated(this.rows, this.title, this.sortKey, this.ascending, this.filter,
      this.extra);
}

class _SentinelTableState {
  final int _rows;
  final int title;
  final int sortKey;
  final bool ascending;
  final String filter;
  _SentinelTableState(
      this._rows, this.title, this.sortKey, this.ascending, this.filter);

  String render() {
    if (title > 0) {
      return _buildToolbarHtml(_rows, title, sortKey, ascending, filter, 1) +
          _renderRows(_rows, title, sortKey, ascending);
    }
    return '';
  }

  String _renderRows(int rows, int title, int sortKey, bool ascending) =>
      '\$rows \$title \$sortKey \$ascending';
}

String _buildToolbarHtml(
    int rows, int title, int sortKey, bool ascending, String filter, int extra) {
  if (ascending) return '\$rows \$title \$sortKey \$filter \$extra';
  return '';
}
''';
      final report = ShallowAnalyzer().analyzeCode(code);
      final byName = {for (final f in report.findings) f.name: f};
      check(byName.keys).unorderedEquals([
        '_buildToolbarHtml',
        '_SentinelTableState._renderRows',
      ]);

      // Top-level helper: highest field coverage wins (6 of 6 in _Unrelated).
      final toolbar = byName['_buildToolbarHtml']!;
      check(toolbar.paramsSubsetOfExistingType).equals('_Unrelated');
      check(
        toolbar.sharedParamSignatureWith,
      ).equals('_SentinelTableState._renderRows');
      check(toolbar.sharedParamCount).equals(4);

      // Method: the enclosing type is preferred on a 4-vs-4 tie, and `_rows`
      // matches `rows` because leading underscores are ignored.
      final rows = byName['_SentinelTableState._renderRows']!;
      check(rows.paramsSubsetOfExistingType).equals('_SentinelTableState');
      check(
        rows.toJson()['params_subset_of_existing_type'],
      ).equals('_SentinelTableState');
      check(report.formatText()).contains(
        'params mirror _SentinelTableState fields '
        '-> pass _SentinelTableState directly',
      );
    });

    test('orders findings by caller-group significance, then simulation '
        'order within a caller', () {
      // `_micro` is a +0 micro-predicate declared first in the file; the
      // HIGH_ARITY `_wide` under a different caller must still print first.
      const significance = '''
void _callerP(int a, int b) {
  if (a > 0) print(_micro(a, b));
}
int _micro(int a, int b) => a + b;

void _callerQ(int a, int b, int c, int d, int e) {
  if (a > 0) _wide(a, b, c, d, e);
}
void _wide(int a, int b, int c, int d, int e) {
  print(a + b + c + d + e);
}
''';
      final ranked = ShallowAnalyzer().analyzeCode(significance);
      check(
        ranked.findings.map((f) => f.name).toList(),
      ).deepEquals(['_wide', '_micro']);

      // `_y` saves more lines than `_x` (the old print key) but `_x` has the
      // lower delta and is simulated first, so `_x` must print first and
      // `_y`'s `(base 1)` line must follow the sibling that produced its
      // cumulative baseline.
      const chained = '''
void _caller(int a, int b, int c, int d, int e, int f) {
  if (a > 0) {
    _x(a, b, c, d, e);
    _y(a, b, c, d, e, f);
  }
}
void _x(int a, int b, int c, int d, int e) {
  if (a > b) print(c + d + e);
}
void _y(int a, int b, int c, int d, int e, int f) {
  if (a > b) {
    if (c > d) print(e + f);
  }
}
''';
      final report = ShallowAnalyzer().analyzeCode(chained);
      final names = report.findings.map((f) => f.name).toList();
      check(names).deepEquals(['_x', '_y']);
      check(
        report.findings.map((f) => f.simulationIndex).toList(),
      ).deepEquals([0, 1]);
      check(
        report.findings.map((f) => f.callerCumulativeBefore).toList(),
      ).deepEquals([1, 3]);
      check(
        report.findings.first.estimatedLinesSaved,
      ).isLessThan(report.findings.last.estimatedLinesSaved);
      check(report.findings.last.toJson()['simulation_index']).equals(1);

      final text = report.formatText();
      check(text.indexOf('Caller CC: 1 -> 3 after inline (+2)')).isLessThan(
        text.indexOf('Caller CC: 3 (base 1) -> 8 after inline (+5)'),
      );
    });

    test('CLI --git-diff filters modified files when run from a workspace '
        'subpackage directory', () async {
      await d.dir('ws_repo', [
        d.dir('packages', [
          d.dir('sub_pkg', [
            d.file('pubspec.yaml', 'name: sub_pkg\n'),
            d.dir('lib', [
              d.file('unmodified.dart', '''
void keepCaller(int a, int b, int c, int d, int e) {
  _unmodifiedHelper(a, b, c, d, e);
}

void _unmodifiedHelper(int a, int b, int c, int d, int e) {
  print(a + b + c + d + e);
}
'''),
              d.file('modified.dart', '''
void modCaller(int a, int b, int c, int d, int e) {
  print(a + b + c + d + e);
}
'''),
            ]),
          ]),
        ]),
      ]).create();

      final repoRoot = '${d.sandbox}/ws_repo';
      Future<void> runGit(List<String> args) async {
        final res = await Process.run('git', args, workingDirectory: repoRoot);
        check(res.exitCode).equals(0);
      }

      await runGit(['init']);
      await runGit(['config', 'user.email', 'test@example.com']);
      await runGit(['config', 'user.name', 'Test User']);
      await runGit(['add', '.']);
      await runGit(['commit', '-m', 'Initial commit']);

      File('$repoRoot/packages/sub_pkg/lib/modified.dart').writeAsStringSync('''
void modCaller(int a, int b, int c, int d, int e) {
  _modifiedHelper(a, b, c, d, e);
}

void _modifiedHelper(int a, int b, int c, int d, int e) {
  print(a + b + c + d + e);
}
''');
      await runGit(['add', '.']);
      await runGit(['commit', '-m', 'Add _modifiedHelper']);

      final prevCurrent = Directory.current;
      final out = StringBuffer();
      final err = StringBuffer();
      late final int exitCode;
      try {
        Directory.current = '$repoRoot/packages/sub_pkg';
        exitCode = await runShallowCli(
          ['--format=json', '--git-diff=HEAD~1', 'lib'],
          out: out,
          err: err,
        );
      } finally {
        Directory.current = prevCurrent;
      }

      check(exitCode).equals(0);
      final json = jsonDecode(out.toString()) as Map<String, dynamic>;
      final findings = json['findings'] as List<dynamic>;
      check(findings.length).equals(1);
      final single = findings.single as Map<String, dynamic>;
      check(single['name']).equals('_modifiedHelper');
    });

    test(
      'CLI supports --help, --only-safe, and --fail-on-safe-inline',
      () async {
        final helpProc = await TestProcess.start(dartExe, [binPath, '--help']);
        final helpOut = await helpProc.stdoutStream().join('\n');
        await helpProc.shouldExit(0);
        check(
          helpOut,
        ).contains('Dart Single-Caller Shallow Helper & Inlining Advisor');

        await d.dir('fail_pkg', [
          d.dir('lib', [
            d.file('app.dart', '''
void runApp(int a, int b, int c, int d, int e) {
  _trampoline(a, b, c, d, e);
}

void _trampoline(int a, int b, int c, int d, int e) {
  print(a + b + c + d + e);
}
'''),
          ]),
        ]).create();

        final out = StringBuffer();
        final err = StringBuffer();
        final code = await runShallowCli(
          ['--only-safe', '--fail-on-safe-inline', '${d.sandbox}/fail_pkg/lib'],
          out: out,
          err: err,
        );
        check(code).equals(1);
        check(out.toString()).contains('[SAFE_INLINE]');
        check(
          err.toString(),
        ).contains('SAFE_INLINE shallow helper(s) detected');
      },
    );

    test('weights multi-arm switch expressions and statements in '
        'statement_count so lookup tables are not MICRO_HELPER', () {
      const code = '''
String describeKind(int kind, int? baseline) {
  return '\${_kindLabel(kind)}:\${_deltaIcon(kind, baseline)}:'
      '\${_statementLookup(kind)}:\${_twoArmSwitch(kind)}';
}

String _kindLabel(int kind) => switch (kind) {
  0 => 'alpha',
  1 => 'beta',
  2 => 'gamma',
  3 => 'delta',
  4 => 'epsilon',
  _ => 'other',
};

String _deltaIcon(int score, int? base) {
  if (base == null) return 'new';
  return switch (score.compareTo(base)) {
    > 0 => 'up',
    < 0 => 'down',
    0 => 'same',
    _ => 'unknown',
  };
}

String _statementLookup(int kind) {
  switch (kind) {
    case 0:
      return 'zero';
    case 1:
      return 'one';
    case 2:
      return 'two';
    case 3:
      return 'three';
    default:
      return 'many';
  }
}

String _twoArmSwitch(int kind) => switch (kind) {
  0 =>
    'zero_value_'
        'wrapped_across_lines',
  _ =>
    'nonzero_value_'
        'wrapped_across_lines',
};
''';
      final report = ShallowAnalyzer().analyzeCode(code);
      // `_kindLabel` (6-arm switch expr -> 6 stmts), `_deltaIcon` (1 guard +
      // 4-arm switch expr -> 5 stmts), and `_statementLookup` (5-arm switch
      // stmt -> 5 stmts) all exceed 6 body lines and 2 statements, so none are
      // flagged as MICRO_HELPER. `_twoArmSwitch` (2 arms -> 2 stmts across 8
      // body lines) IS still flagged as MICRO_HELPER.
      check(
        report.findings.map((f) => f.name).toList(),
      ).deepEquals(['_twoArmSwitch']);
      final twoArm = report.findings.single;
      check(twoArm.statementCount).equals(2);
      check(twoArm.bodyLines).isGreaterThan(6);
      check(twoArm.reasons.any((r) => r.startsWith('MICRO_HELPER'))).isTrue();
    });

    test('switch statement arm counting ignores stacked empty case labels, '
        'empty switches, and nested closures', () {
      const code = '''
void caller(int a, int b, int c, int d, int e) {
  _stackedCases(a, b, c, d, e);
  _emptySwitchAndClosure(a, b, c, d, e);
}

String _stackedCases(int a, int b, int c, int d, int e) {
  switch (a + b + c + d + e) {
    case 0:
    case 1:
    case 2:
      return 'small';
    default:
      return 'large';
  }
}

int _emptySwitchAndClosure(int a, int b, int c, int d, int e) {
  switch (a) {}
  final f = (int x) => switch (x) {
    0 => 10,
    1 => 20,
    2 => 30,
    _ => 40,
  };
  return f(b + c + d + e);
}
''';
      final report = ShallowAnalyzer().analyzeCode(code);
      final byName = {for (final f in report.findings) f.name: f};

      // `_stackedCases` has 1 top-level SwitchStatement with 2 non-empty
      // members (`case 2` and `default`), so statementCount = 1 + (2 - 1) = 2.
      final stacked = byName['_stackedCases']!;
      check(stacked.statementCount).equals(2);

      // `_emptySwitchAndClosure` has 3 top-level statements (`switch (a) {}`,
      // `final f = ...`, `return ...`). The empty switch contributes
      // max(0, 0 - 1) = 0 (no underflow), and the 4-arm switch inside closure
      // `f` is excluded by nested-function boundary stopping.
      final emptyAndClosure = byName['_emptySwitchAndClosure']!;
      check(emptyAndClosure.statementCount).equals(3);
    });
  });
}
