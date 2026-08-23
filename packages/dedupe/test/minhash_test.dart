import 'package:checks/checks.dart';
import 'package:dedupe/dedupe.dart';
import 'package:dedupe/src/ast_extractor.dart';
import 'package:dedupe/src/detector.dart';
import 'package:dedupe/src/minhash.dart';
import 'package:test/test.dart';

void main() {
  group('MinHasher', () {
    final minHasher = MinHasher();

    test('empty set returns empty signature', () {
      final sig = minHasher.computeSignature({});
      check(sig.isEmpty).equals(true);
    });

    test('identical sets produce identical signatures', () {
      final setA = {10, 20, 30, 40, 50, 60, 70, 80};
      final setB = {10, 20, 30, 40, 50, 60, 70, 80};

      final sigA = minHasher.computeSignature(setA);
      final sigB = minHasher.computeSignature(setB);

      check(sigA.length).equals(16);
      check(sigB.length).equals(16);
      check(MinHasher.estimateSimilarity(sigA, sigB)).equals(1.0);
      check(MinHasher.exactJaccard(setA, setB)).equals(1.0);
    });

    test('near-miss sets produce high estimated similarity', () {
      final setA = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10};
      final setB = {
        1,
        2,
        3,
        4,
        5,
        6,
        7,
        8,
        9,
        999,
      }; // 9 out of 11 union shared = 81.8%

      final sigA = minHasher.computeSignature(setA);
      final sigB = minHasher.computeSignature(setB);

      final exact = MinHasher.exactJaccard(setA, setB);
      check(exact).isGreaterThan(0.80);

      final estimated = MinHasher.estimateSimilarity(sigA, sigB);
      check(estimated).isGreaterThan(0.60);
    });

    test('disjoint sets produce low similarity', () {
      final setA = {1, 2, 3, 4, 5};
      final setB = {100, 200, 300, 400, 500};

      final exact = MinHasher.exactJaccard(setA, setB);
      check(exact).equals(0.0);
    });
  });

  group('LshIndex', () {
    test('indexes and retrieves matching candidate pairs', () {
      final minHasher = MinHasher();
      final lsh = LshIndex<String>(minHasher: minHasher);

      final set1 = {10, 20, 30, 40, 50, 60, 70, 80};
      final set2 = {10, 20, 30, 40, 50, 60, 70, 99}; // High similarity
      final set3 = {500, 600, 700, 800, 900}; // Unrelated

      lsh.insert('item1', minHasher.computeSignature(set1));
      lsh.insert('item2', minHasher.computeSignature(set2));
      lsh.insert('item3', minHasher.computeSignature(set3));

      final pairs = lsh.findCandidatePairs();
      check(
        pairs.any(
          (p) =>
              (p.item1 == 'item1' && p.item2 == 'item2') ||
              (p.item1 == 'item2' && p.item2 == 'item1'),
        ),
      ).equals(true);
    });
  });

  group('CloneDetector Type-3 Gapped Clones', () {
    test('detects near-miss functions with a gapped line', () {
      const codeA = r'''
void handleUserOrder(String userId, double amount) {
  if (userId.isEmpty) throw ArgumentError('Invalid user');
  final normalizedAmount = amount.abs();
  print('Processing order for $userId: $normalizedAmount');
  print('Checking inventory status');
  print('Reserving warehouse items');
  print('Dispatching notification event');
  print('Transaction successfully completed');
}
''';

      const codeB = r'''
void handleUserOrder(String userId, double amount) {
  if (userId.isEmpty) throw ArgumentError('Invalid user');
  final normalizedAmount = amount.abs();
  print('Processing order for $userId: $normalizedAmount');
  print('EXTRA LOGGING: Order audit trace active');
  print('Checking inventory status');
  print('Reserving warehouse items');
  print('Dispatching notification event');
  print('Transaction successfully completed');
}
''';

      const extractor = AstExtractor(
        minTokens: 15,
        minLines: 4,
        ignoreComments: true,
        ignoreLiterals: true,
      );

      final (seqA, candA) = extractor.extract(
        filePath: 'lib/order_a.dart',
        content: codeA,
        fileIndex: 0,
      );
      final (seqB, candB) = extractor.extract(
        filePath: 'lib/order_b.dart',
        content: codeB,
        fileIndex: 1,
      );

      const detector = CloneDetector(minTokens: 15, minLines: 4);
      final clusters = detector.detect(
        [seqA, seqB],
        candidates: [...candA, ...candB],
      );

      check(clusters.isNotEmpty).equals(true);
      final cluster = clusters.first;
      check(cluster.instances.length).equals(2);
      check(cluster.bucket).equals(CloneBucket.gapped);
      check(cluster.instances[0].filePath).equals('lib/order_a.dart');
      check(cluster.instances[1].filePath).equals('lib/order_b.dart');
    });

    test('does not pair functions with identical statement sketches but '
        'divergent token contents', () {
      const codeA = r'''
void logMetricsAlpha(int alpha, int beta) {
  final result = alpha + beta;
  print('Metric alpha computed: $result');
  print('Dispatching alpha to telemetry');
  print('Updating alpha cache state');
  print('Finalizing alpha transaction');
}
''';

      const codeB = r'''
void sendEmailNotification(String recipient, String message) {
  final status = recipient.isNotEmpty;
  print('Sending notification to $recipient: $status');
  print('Writing message payload to SMTP socket');
  print('Awaiting server confirmation packet');
  print('Closing SMTP connection socket');
}
''';

      const extractor = AstExtractor(
        minTokens: 15,
        minLines: 4,
        ignoreComments: true,
        ignoreLiterals: false,
      );

      final (seqA, candA) = extractor.extract(
        filePath: 'lib/metrics.dart',
        content: codeA,
        fileIndex: 0,
      );
      final (seqB, candB) = extractor.extract(
        filePath: 'lib/email.dart',
        content: codeB,
        fileIndex: 1,
      );

      const detector = CloneDetector(minTokens: 15, minLines: 4);
      final clusters = detector.detect(
        [seqA, seqB],
        candidates: [...candA, ...candB],
      );

      check(clusters.isEmpty).equals(true);
    });
  });
}
