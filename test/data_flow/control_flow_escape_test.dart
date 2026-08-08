import 'package:checks/checks.dart';
import 'package:cognitive_complexity/data_flow.dart';
import 'package:test/scaffolding.dart';

void main() {
  group('ControlFlowEscape Detection', () {
    const analyzer = DataFlowAnalyzer();

    test('Detects early return statement as control flow escape', () async {
      const code = '''
void checkValue(int x) {
  print('Start');
  // Target: Lines 4-6
  if (x < 0) {
    return;
  }
  // Post: Line 8
  print('End');
}
''';

      final result = await analyzer.analyzeSource(
        sourceCode: code,
        startLine: 4,
        endLine: 6,
      );

      check(result.isCleanlyExtractable).isFalse();
      check(result.escapes).length.equals(1);
      check(
        result.escapes.first.type,
      ).equals(ControlFlowEscapeType.earlyReturn);
      check(result.escapes.first.line).equals(5);
    });

    test('Return inside an internal lambda is NOT a control escape', () async {
      const code = '''
void filterNumbers(List<int> numbers) {
  print('Start');
  // Target: Lines 4-6
  final evens = numbers.where((n) {
    return n % 2 == 0;
  }).toList();
  // Post: Line 8
  print(evens);
}
''';

      final result = await analyzer.analyzeSource(
        sourceCode: code,
        startLine: 4,
        endLine: 6,
      );

      check(result.isCleanlyExtractable).isTrue();
      check(result.escapes).isEmpty();
      check(result.outputs.map((o) => o.name).toList()).deepEquals(['evens']);
    });

    test('Break targeting outer loop is flagged as loopBreak escape', () async {
      const code = '''
void searchLoop(List<String> items) {
  for (final item in items) {
    // Target: Lines 4-6
    if (item == 'stop') {
      break;
    }
    // Post: Line 8
    print(item);
  }
}
''';

      final result = await analyzer.analyzeSource(
        sourceCode: code,
        startLine: 4,
        endLine: 6,
      );

      check(result.isCleanlyExtractable).isFalse();
      check(result.escapes).length.equals(1);
      check(result.escapes.first.type).equals(ControlFlowEscapeType.loopBreak);
      check(result.escapes.first.line).equals(5);
    });

    test('Break targeting internal loop is NOT an escape', () async {
      const code = '''
void internalLoop() {
  print('Start');
  // Target: Lines 4-8
  for (var i = 0; i < 10; i++) {
    if (i == 5) {
      break;
    }
  }
  // Post: Line 10
  print('Done');
}
''';

      final result = await analyzer.analyzeSource(
        sourceCode: code,
        startLine: 4,
        endLine: 8,
      );

      check(result.isCleanlyExtractable).isTrue();
      check(result.escapes).isEmpty();
    });
  });
}
