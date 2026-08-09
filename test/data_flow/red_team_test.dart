import 'package:checks/checks.dart';
import 'package:cognitive_complexity/data_flow.dart';
import 'package:test/scaffolding.dart';

void main() {
  group('Red Team Findings', () {
    const analyzer = DataFlowAnalyzer();

    test('VULN-01: Pattern Assignment LHS Mutations', () async {
      const code = '''
void testMethod(int a, int b) {
  print('start');
  // Target: Lines 4-4
  (a, b) = (b, a);
  // Post: Line 6
  print(a + b);
}
''';
      final result = await analyzer.analyzeSource(
        sourceCode: code,
        startLine: 4,
        endLine: 4,
      );
      check(result.isCleanlyExtractable).isTrue();
      check(
        result.mutations.map((m) => m.name).toList()..sort(),
      ).deepEquals(['a', 'b']);
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

    test('VULN-03: await for stream loops', () async {
      const code = '''
void testMethod(Stream<int> stream) async {
  print('start');
  // Target: Lines 4-6
  await for (final item in stream) {
    print(item);
  }
  print('end');
}
''';
      final result = await analyzer.analyzeSource(
        sourceCode: code,
        startLine: 4,
        endLine: 6,
      );
      check(result.suggestedSignature).contains('async');
      check(result.suggestedSignature).contains('Future');
    });

    test('VULN-04: Illegal private record field names', () async {
      const code = '''
class CounterManager {
  void process() {
    int _counter = 0;
    int _total = 10;
    // Target: Lines 6-7
    _counter += 1;
    _total += 2;
    print('\$_counter \$_total');
  }
}
''';
      final result = await analyzer.analyzeSource(
        sourceCode: code,
        startLine: 6,
        endLine: 7,
      );
      check(result.suggestedSignature).not((it) => it.contains('{int _'));
      check(result.suggestedSignature).contains('({int counter, int total})');
    });

    test('VULN-05: Type promotion lost across extraction boundaries', () async {
      const code = '''
void testMethod(Object obj) {
  if (obj is String) {
    // Target: Lines 4-5
    print(obj.length);
    print(obj.toUpperCase());
  }
}
''';
      final result = await analyzer.analyzeSource(
        sourceCode: code,
        startLine: 4,
        endLine: 5,
      );
      check(result.suggestedSignature).contains('(String obj)');
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

    test('VULN-09: Enclosing method type parameters omitted', () async {
      const code = '''
void process<T>(T item) {
  // Target: Lines 3-3
  print(item);
}
''';
      final result = await analyzer.analyzeSource(
        sourceCode: code,
        startLine: 3,
        endLine: 3,
      );
      check(result.suggestedSignature).contains('<T>');
    });

    test('VULN-10: Pattern variable declarations', () async {
      const code = '''
void testMethod(List<int> list) {
  print('start');
  // Target: Lines 4-4
  final [a, b, ...rest] = list;
  // Post: Line 6
  print(a + b);
}
''';
      final result = await analyzer.analyzeSource(
        sourceCode: code,
        startLine: 4,
        endLine: 4,
      );
      check(result.isCleanlyExtractable).isTrue();
      check(
        result.outputs.map((o) => o.name).toList()..sort(),
      ).deepEquals(['a', 'b']);
    });
  });
}
