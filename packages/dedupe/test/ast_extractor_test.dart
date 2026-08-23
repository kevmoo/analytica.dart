import 'package:checks/checks.dart';
import 'package:dedupe/src/ast_extractor.dart';
import 'package:dedupe/src/detector.dart';
import 'package:test/test.dart';

void main() {
  group('AstExtractor', () {
    test('extracts function declarations and blocks', () {
      const code = r'''
void calculateMetrics(int total, int count) {
  if (count <= 0) {
    throw ArgumentError('Count must be positive');
  }
  final average = total / count;
  print('Average is $average');
  print('Processed $count items');
}
''';

      const extractor = AstExtractor(
        minTokens: 10,
        minLines: 3,
        ignoreComments: true,
        ignoreLiterals: true,
      );

      final (sequence, candidates) = extractor.extract(
        filePath: 'lib/metrics.dart',
        content: code,
        fileIndex: 0,
      );

      check(sequence.tokens.length > 20).equals(true);
      check(candidates.isNotEmpty).equals(true);

      final funcCandidate = candidates.firstWhere(
        (c) => c.astNodeType == 'FunctionDeclaration',
      );
      check(funcCandidate.startLine).equals(1);
      check(funcCandidate.endLine).equals(8);
      check(funcCandidate.isDeclaration).equals(true);

      final ifCandidate = candidates.firstWhere(
        (c) => c.astNodeType == 'IfStatement',
      );
      check(ifCandidate.startLine).equals(2);
      check(ifCandidate.endLine).equals(4);
    });

    test('extracts class methods and constructors', () {
      const code = r'''
class ServiceClient {
  final String host;
  final int port;

  ServiceClient(this.host, this.port) {
    if (host.isEmpty) {
      throw ArgumentError('Host cannot be empty');
    }
  }

  void connect() {
    print('Connecting to $host:$port');
    print('Socket initialized');
    print('Handshake complete');
  }
}
''';

      const extractor = AstExtractor(
        minTokens: 8,
        minLines: 2,
        ignoreComments: true,
        ignoreLiterals: true,
      );

      final (_, candidates) = extractor.extract(
        filePath: 'lib/client.dart',
        content: code,
        fileIndex: 0,
      );

      final constructorCandidate = candidates.firstWhere(
        (c) => c.astNodeType == 'ConstructorDeclaration',
      );
      check(constructorCandidate.startLine).equals(5);
      check(constructorCandidate.endLine).equals(9);

      final methodCandidate = candidates.firstWhere(
        (c) => c.astNodeType == 'MethodDeclaration',
      );
      check(methodCandidate.startLine).equals(11);
      check(methodCandidate.endLine).equals(15);
    });

    test('CloneDetector clusters matching AST candidates across files', () {
      const codeA = r'''
void processData(List<String> items) {
  for (final item in items) {
    if (item.isEmpty) continue;
    print('Item: $item');
    print('Processed: $item');
  }
}
''';

      const codeB = r'''
void processData(List<String> items) {
  for (final item in items) {
    if (item.isEmpty) continue;
    print('Item: $item');
    print('Processed: $item');
  }
}
''';

      const extractor = AstExtractor(
        minTokens: 10,
        minLines: 3,
        ignoreComments: true,
        ignoreLiterals: true,
      );

      final (seqA, candA) = extractor.extract(
        filePath: 'lib/a.dart',
        content: codeA,
        fileIndex: 0,
      );
      final (seqB, candB) = extractor.extract(
        filePath: 'lib/b.dart',
        content: codeB,
        fileIndex: 1,
      );

      const detector = CloneDetector(minTokens: 10, minLines: 3);
      final clusters = detector.detect(
        [seqA, seqB],
        candidates: [...candA, ...candB],
      );

      check(clusters.isNotEmpty).equals(true);
      final cluster = clusters.first;
      check(cluster.instances.length).equals(2);
      check(cluster.instances[0].filePath).equals('lib/a.dart');
      check(cluster.instances[1].filePath).equals('lib/b.dart');
    });
  });
}
