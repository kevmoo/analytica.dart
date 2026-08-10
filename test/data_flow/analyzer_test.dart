import 'package:checks/checks.dart';
import 'package:cognitive_complexity/data_flow.dart';
import 'package:test/scaffolding.dart';

void main() {
  group('DataFlowAnalyzer', () {
    const analyzer = DataFlowAnalyzer();

    test('Identifies read-only inputs without mutations or outputs', () async {
      const code = '''
void process(int a, String b) {
  print('Start');
  // Target: Lines 4-5
  final sum = a + b.length;
  print(sum);
  // Post: Line 7
  print('Done');
}
''';

      final result = await analyzer.analyzeSource(
        sourceCode: code,
        startLine: 4,
        endLine: 5,
      );

      check(result.isCleanlyExtractable).isTrue();
      check(result.enclosingDeclaration).equals('process');
      check(result.inputs.map((i) => i.name).toList()).deepEquals(['a', 'b']);
      check(result.mutations).isEmpty();
      check(result.outputs).isEmpty();
      check(
        result.suggestedSignature,
      ).equals('void _extracted(int a, String b)');
    });

    test(
      'Identifies mutated variable and returns it if read afterwards',
      () async {
        const code = '''
void counter() {
  int count = 0;
  // Target: Lines 4-5
  count += 5;
  print('Incremented');
  // Post: Line 7
  print(count);
}
''';

        final result = await analyzer.analyzeSource(
          sourceCode: code,
          startLine: 4,
          endLine: 5,
        );

        check(result.isCleanlyExtractable).isTrue();
        check(result.inputs.map((i) => i.name).toList()).deepEquals(['count']);
        check(result.inputs.first.isMutated).isTrue();
        check(
          result.mutations.map((m) => m.name).toList(),
        ).deepEquals(['count']);
        check(result.outputs.map((o) => o.name).toList()).deepEquals(['count']);
        check(result.suggestedSignature).equals('int _extracted(int count)');
      },
    );

    test(
      'Creates Dart 3 Record when multiple outputs are live afterwards',
      () async {
        const code = '''
void authenticate(String token, int retry) {
  bool ok = false;
  // Target: Lines 4-6
  if (token.isNotEmpty) {
    ok = true;
  }
  final user = ok ? 'User_\$token' : null;
  // Post: Line 8
  if (ok && user != null) {
    print(user);
  }
}
''';

        final result = await analyzer.analyzeSource(
          sourceCode: code,
          startLine: 4,
          endLine: 7,
          methodName: '_authenticate',
        );

        check(result.isCleanlyExtractable).isTrue();
        check(
          result.inputs.map((i) => i.name).toList(),
        ).deepEquals(['token', 'ok']);
        check(
          result.outputs.map((o) => o.name).toList(),
        ).deepEquals(['ok', 'user']);
        check(result.suggestedSignature).equals(
          '({bool ok, String? user}) _authenticate(String token, bool ok)',
        );
      },
    );

    test('Ignores local variables discarded within the slice', () async {
      const code = '''
void testDiscard() {
  int x = 10;
  // Target: Lines 4-6
  final temp = x * 2;
  print(temp);
  final result = temp + 5;
  // Post: Line 8
  print(result);
}
''';

      final result = await analyzer.analyzeSource(
        sourceCode: code,
        startLine: 4,
        endLine: 6,
      );

      check(result.inputs.map((i) => i.name).toList()).deepEquals(['x']);
      // 'temp' is discarded inside slice, only 'result' is read afterwards
      check(result.outputs.map((o) => o.name).toList()).deepEquals(['result']);
      check(result.suggestedSignature).equals('int _extracted(int x)');
    });

    test(
      'Object property access is an input, not a variable reassignment',
      () async {
        const code = '''
class Model {
  int value = 0;
}

void modify(Model m) {
  // Target: Lines 7-8
  m.value = 42;
  print(m.value);
  // Post: Line 10
  print(m.value);
}
''';

        final result = await analyzer.analyzeSource(
          sourceCode: code,
          startLine: 7,
          endLine: 8,
        );

        check(result.inputs.map((i) => i.name).toList()).deepEquals(['m']);
        // m is modified via property access, not reassigned
        check(result.mutations).isEmpty();
        check(result.outputs).isEmpty();
        check(result.suggestedSignature).equals('void _extracted(Model m)');
      },
    );

    test('Handles async operations with Future<T> signatures', () async {
      const code = '''
Future<void> fetchFlow(String url) async {
  // Target: Lines 3-4
  final response = await Future.value('data from \$url');
  print('done');
  // Post: Line 6
  print(response);
}
''';

      final result = await analyzer.analyzeSource(
        sourceCode: code,
        startLine: 3,
        endLine: 4,
        methodName: '_fetchData',
      );

      check(result.inputs.map((i) => i.name).toList()).deepEquals(['url']);
      check(
        result.outputs.map((o) => o.name).toList(),
      ).deepEquals(['response']);
      check(
        result.suggestedSignature,
      ).equals('Future<String> _fetchData(String url) async');
    });

    test('Analyzes target slices within class methods', () async {
      const code = '''
class Service {
  void performTask(int id) {
    final prefix = 'ID:';
    // Target: Lines 5-6
    final message = '\$prefix \$id';
    print(message);
    // Post: Line 8
    print(message.length);
  }
}
''';

      final result = await analyzer.analyzeSource(
        sourceCode: code,
        startLine: 5,
        endLine: 6,
      );

      check(result.enclosingDeclaration).equals('performTask');
      check(
        result.inputs.map((i) => i.name).toList(),
      ).deepEquals(['prefix', 'id']);
      check(result.outputs.map((o) => o.name).toList()).deepEquals(['message']);
    });

    test('Ignores top-level constants and static fields from inputs', () async {
      const code = '''
const String globalConfig = 'PROD';

class App {
  static const int maxRetries = 3;

  void run(int attempt) {
    // Target: Lines 8-9
    final shouldRetry = attempt < maxRetries;
    print('\$globalConfig: \$shouldRetry');
  }
}
''';

      final result = await analyzer.analyzeSource(
        sourceCode: code,
        startLine: 8,
        endLine: 9,
      );

      check(result.inputs.map((i) => i.name).toList()).deepEquals(['attempt']);
      check(result.mutations).isEmpty();
      check(result.outputs).isEmpty();
    });

    test('Handles slice extending to closing line of function', () async {
      const code = '''
void helper(int x) {
  // Target: Lines 3-4
  final y = x * 2;
  print(y);
}
''';

      final result = await analyzer.analyzeSource(
        sourceCode: code,
        startLine: 3,
        endLine: 4,
      );

      check(result.isCleanlyExtractable).isTrue();
      check(result.inputs.map((i) => i.name).toList()).deepEquals(['x']);
    });
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

    test(
      'Reports first mutation line when a variable is mutated twice',
      () async {
        const code = '''
void twice() {
  int x = 0;
  // Target: Lines 4-5
  x = 1;
  x = 2;
  // Post: Line 7
  print(x);
}
''';
        final result = await analyzer.analyzeSource(
          sourceCode: code,
          startLine: 4,
          endLine: 5,
        );
        check(result.mutations.single.firstMutationLine).equals(4);
        check(result.inputs.single.firstMutationLine).equals(4);
      },
    );

    test('Preserves type parameter bounds in synthesized signature', () async {
      const code = '''
T process<T extends num>(T item) {
  // Target: Line 3
  print(item);
  return item;
}
''';
      final result = await analyzer.analyzeSource(
        sourceCode: code,
        startLine: 3,
        endLine: 3,
      );
      check(result.suggestedSignature).contains('<T extends num>');
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
