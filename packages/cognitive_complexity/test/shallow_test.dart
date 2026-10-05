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
        check(finding.callerScore).equals(3);
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
        check(finding.callerScore).equals(10);
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
        check(f.callerScore).equals(f.callerCumulativeBefore);
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
      check(h2Json['caller_score']).equals(6);
      check(h2Json['inlined_caller_score']).equals(9);

      final text = report.formatText();
      check(text).contains('Caller CC: 3 -> 6 after inline (+3)');
      check(text).contains('Caller CC: 6 (base 3) -> 9 after inline (+3)');
      check(text).contains('Caller CC: 9 (base 3) -> 12 after inline (+3)');
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
  });
}
