import 'package:checks/checks.dart';
import 'package:cognitive_complexity/cognitive_complexity.dart';
import 'package:cognitive_complexity/src/shallow/cli.dart';
import 'package:test/test.dart';

void main() {
  group('Metamorphic properties', () {
    test('classification unchanged by rename, reorder, reformat, comment', () {
      final code1 = '''
void _loadProcA(int x) { if (x > 1) print(x); }
void _loadProcB(int x, int y) { if (x > 1) print(y); }
void run(int x) {
  _loadProcA(x);
  _loadProcB(x, x);
}
''';
      // Same AST structure, different names, order, format, and comments
      final code2 = '''
// Main run func
void exec(int q) {
  _fetchProcY(q, q);
  _fetchProcX(q);
}

void _fetchProcX(int q) {
  if (q > 1) {
    print(q);
  }
}

/* 
 * multi
 * line 
 */
void _fetchProcY(int q, int r) {
  if (q > 1) print(r);
}
''';

      final r1 = ShallowAnalyzer().analyzeCode(code1);
      final r2 = ShallowAnalyzer().analyzeCode(code2);

      check(
        r1.findings.singleWhere((f) => f.name == '_loadProcA').classification,
      ).equals(ShallowClassification.siblingStep);
      check(
        r1.findings.singleWhere((f) => f.name == '_loadProcB').classification,
      ).equals(ShallowClassification.siblingStep);

      check(
        r2.findings.singleWhere((f) => f.name == '_fetchProcX').classification,
      ).equals(ShallowClassification.siblingStep);
      check(
        r2.findings.singleWhere((f) => f.name == '_fetchProcY').classification,
      ).equals(ShallowClassification.siblingStep);
    });

    test('adding/removing a same-stem sibling flips classification', () {
      final code1 = '''
void _loadProcA(int x) { if (x > 1) print(x); }
void run(int x) {
  _loadProcA(x);
}
''';
      final code2 = '''
void _loadProcA(int x) { if (x > 1) print(x); }
void _loadProcB(int x, int y) { if (x > 1) print(y); }
void run(int x) {
  _loadProcA(x);
  _loadProcB(x, x);
}
''';
      final r1 = ShallowAnalyzer().analyzeCode(code1);
      final r2 = ShallowAnalyzer().analyzeCode(code2);

      // With no sibling, it is SAFE_INLINE
      check(
        r1.findings.singleWhere((f) => f.name == '_loadProcA').classification,
      ).equals(ShallowClassification.safeInline);

      // Adding a same-stem sibling flips it to SIBLING_STEP
      check(
        r2.findings.singleWhere((f) => f.name == '_loadProcA').classification,
      ).equals(ShallowClassification.siblingStep);
    });

    test('crossing the ceiling flips classification', () {
      // 15 is the default ceiling.
      final code1 =
          '''
void _doX(int x) { if (x > 1) print(x); }
void run(int x) {
  _doX(x);
''' +
          List.generate(13, (i) => '  if (x == \$i) print(x);').join('\n') +
          '''
}
''';
      final code2 =
          '''
void _doX(int x) { if (x > 1) print(x); }
void run(int x) {
  _doX(x);
''' +
          List.generate(14, (i) => '  if (x == \$i) print(x);').join('\n') +
          '''
}
''';
      final r1 = ShallowAnalyzer().analyzeCode(code1);
      final r2 = ShallowAnalyzer().analyzeCode(code2);

      // Before ceiling, SAFE_INLINE
      check(
        r1.findings.singleWhere((f) => f.name == '_doX').classification,
      ).equals(ShallowClassification.safeInline);

      // Crossing ceiling, zeroHeadroom
      check(
        r2.findings.singleWhere((f) => f.name == '_doX').classification,
      ).equals(ShallowClassification.zeroHeadroom);
    });
  });
}
