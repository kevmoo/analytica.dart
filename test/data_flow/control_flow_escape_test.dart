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

    test(
      'Break targeting internal switch statement is NOT an escape',
      () async {
        const code = '''
void handleSwitch(int code) {
  print('Start');
  // Target: Lines 4-10
  switch (code) {
    case 1:
      print('One');
      break;
    default:
      print('Other');
  }
  // Post: Line 12
  print('Done');
}
''';

        final result = await analyzer.analyzeSource(
          sourceCode: code,
          startLine: 4,
          endLine: 10,
        );

        check(result.isCleanlyExtractable).isTrue();
        check(result.escapes).isEmpty();
      },
    );

    test(
      'Continue inside switch targeting outer loop IS flagged as escape',
      () async {
        const code = '''
void loopWithSwitch(List<int> items) {
  for (final item in items) {
    // Target: Lines 4-10
    switch (item) {
      case 0:
        continue;
      default:
        print(item);
    }
    // Post: Line 12
    print('After switch');
  }
}
''';

        final result = await analyzer.analyzeSource(
          sourceCode: code,
          startLine: 4,
          endLine: 10,
        );

        check(result.isCleanlyExtractable).isFalse();
        check(result.escapes).length.equals(1);
        check(
          result.escapes.first.type,
        ).equals(ControlFlowEscapeType.loopContinue);
        check(result.escapes.first.line).equals(6);
      },
    );

    test('Yield statement in generator is flagged as yieldEscape', () async {
      const code = '''
Iterable<int> countUp(int n) sync* {
  print('Start');
  // Target: Lines 4-5
  yield n;
  print('Yielded');
}
''';

      final result = await analyzer.analyzeSource(
        sourceCode: code,
        startLine: 4,
        endLine: 5,
      );

      check(result.isCleanlyExtractable).isFalse();
      check(result.escapes).length.equals(1);
      check(
        result.escapes.first.type,
      ).equals(ControlFlowEscapeType.yieldEscape);
      check(result.escapes.first.line).equals(4);
    });
    test('VULN-02: Labeled jump targeting outer scope', () async {
      const code = '''
void testMethod() {
  outerLoop:
  for (var i = 0; i < 10; i++) {
    // Target: Lines 5-7
    for (var j = 0; j < 5; j++) {
      if (j == 2) break outerLoop;
    }
  }
}
''';
      final result = await analyzer.analyzeSource(
        sourceCode: code,
        startLine: 5,
        endLine: 7,
      );
      check(result.isCleanlyExtractable).isFalse();
      check(result.escapes).isNotEmpty();
    });

    test('VULN-07: rethrow outside catch scope', () async {
      const code = '''
void testMethod() {
  try {
    print('do');
  } catch (e) {
    // Target: Lines 6-7
    print('Failed: \$e');
    rethrow;
  }
}
''';
      final result = await analyzer.analyzeSource(
        sourceCode: code,
        startLine: 6,
        endLine: 7,
      );
      check(result.isCleanlyExtractable).isFalse();
    });

    test(
      'VULN-06: Variable mutation in escaping closures (closureEscape)',
      () async {
        const code = '''
void testMethod(Button button) {
  int count = 0;
  // Target: Lines 4-6
  button.onClick = () {
    count++;
  };
}
class Button {
  void Function()? onClick;
}
''';
        final result = await analyzer.analyzeSource(
          sourceCode: code,
          startLine: 4,
          endLine: 6,
        );
        check(result.isCleanlyExtractable).isFalse();
        check(
          result.escapes.map((e) => e.type.name).toList(),
        ).contains('closureEscape');
        check(result.escapes.first.description).contains('count');
      },
    );

    test(
      'Pattern assignment inside nested closure is flagged as closureEscape',
      () async {
        const code = '''
void testMethod(Button button) {
  int a = 0;
  int b = 1;
  // Target: Lines 5-7
  button.onClick = () {
    (a, b) = (b, a);
  };
}
class Button {
  void Function()? onClick;
}
''';
        final result = await analyzer.analyzeSource(
          sourceCode: code,
          startLine: 5,
          endLine: 7,
        );
        check(result.isCleanlyExtractable).isFalse();
        check(
          result.escapes.map((e) => e.type.name).toList(),
        ).contains('closureEscape');
      },
    );

    test('VULN-08: Slicing inside constructor initializer lists', () async {
      const code = '''
class Point {
  final int x;
  final int y;
  // Target: Lines 6-6
  Point(int a, int b) 
      : x = a * 2, y = b * 2 {
    print('constructed');
  }
}
''';
      final result = await analyzer.analyzeSource(
        sourceCode: code,
        startLine: 6,
        endLine: 6,
      );
      check(result.isCleanlyExtractable).isFalse();
      check(
        result.escapes.map((e) => e.type.name).toList(),
      ).contains('constructorInitializerEscape');
    });
  });
}
