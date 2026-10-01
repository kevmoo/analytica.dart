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
      },
    );

    test(
      'Exempts multi-caller helpers, tear-offs, overrides, build methods, and '
      'ignored declarations',
      () {
        const code = '''
class MyWidget {
  void run(List<int> items) {
    _reused(1, 2);
    _reused(3, 4);
    final mapped = items.map(_tornOff).toList();
    _ignoredHelper(1, 2, 3, 4, 5);
    print(mapped);
  }

  int _reused(int a, int b) => a + b;

  int _tornOff(int x) => x * 2;

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
      },
    );
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

    test('Exempts public API exports, conditional import targets, and helpers '
        'referenced by test/ files', () async {
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

void main() {
  testedInternalFn(42);
}
'''),
        ]),
      ]).create();

      final out = StringBuffer();
      final err = StringBuffer();
      final exitCode = await runShallowCli(
        ['--format=json', '${d.sandbox}/pkg/lib'],
        out: out,
        err: err,
      );

      check(exitCode).equals(0);
      final json = jsonDecode(out.toString()) as Map<String, dynamic>;
      final findings = json['findings'] as List<dynamic>;
      // Only `_shallowHelper` should be flagged; `publicExportedFn` is
      // exported, `platformValue` is a conditional import target, and
      // `testedInternalFn` is called from `test/service_test.dart`.
      check(findings.length).equals(1);
      final single = findings.single as Map<String, dynamic>;
      check(single['name']).equals('_shallowHelper');
      check(single['classification']).equals('SAFE_INLINE');
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
