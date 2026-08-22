import 'package:checks/checks.dart';
import 'package:dedupe/dedupe.dart';
import 'package:test/test.dart';

void main() {
  group('CloneDetector', () {
    test('detects identical clones across two files', () {
      const code1 = '''
void processOrder(int orderId, double price) {
  if (orderId <= 0) {
    throw ArgumentError('Invalid order ID');
  }
  if (price < 0.0) {
    throw ArgumentError('Price cannot be negative');
  }
  print('Processing order \$orderId with total \$price');
}
''';

      const code2 = '''
void processOrder(int orderId, double price) {
  if (orderId <= 0) {
    throw ArgumentError('Invalid order ID');
  }
  if (price < 0.0) {
    throw ArgumentError('Price cannot be negative');
  }
  print('Processing order \$orderId with total \$price');
}
''';

      const tokenizer = DartTokenizer();
      final seq1 = tokenizer.tokenize(
        filePath: 'order_service.dart',
        content: code1,
      );
      final seq2 = tokenizer.tokenize(
        filePath: 'checkout_service.dart',
        content: code2,
      );

      const detector = CloneDetector(minTokens: 20, minLines: 4);
      final clusters = detector.detect([seq1, seq2]);

      check(clusters.length).equals(1);
      final cluster = clusters.first;
      check(cluster.instances.length).equals(2);
      check(cluster.bucket).equals(CloneBucket.identical);
      check(cluster.category).equals(CloneCategory.logic);
      check(cluster.estimatedLinesSaved).isGreaterThan(0);
    });

    test('groups 3 instances into a single cluster', () {
      const helperCode = '''
String formatCurrency(double amount, String symbol) {
  if (amount < 0.0) {
    return '(\$symbol\${(-amount).toStringAsFixed(2)})';
  }
  return '\$symbol\${amount.toStringAsFixed(2)}';
}
''';

      const tokenizer = DartTokenizer();
      final seq1 = tokenizer.tokenize(
        filePath: 'invoice.dart',
        content: helperCode,
      );
      final seq2 = tokenizer.tokenize(
        filePath: 'receipt.dart',
        content: helperCode,
      );
      final seq3 = tokenizer.tokenize(
        filePath: 'statement.dart',
        content: helperCode,
      );

      const detector = CloneDetector(minTokens: 20, minLines: 3);
      final clusters = detector.detect([seq1, seq2, seq3]);

      check(clusters.length).equals(1);
      final cluster = clusters.first;
      check(cluster.instances.length).equals(3);
      check(
        cluster.instances.map((i) => i.filePath).toSet(),
      ).unorderedEquals({'invoice.dart', 'receipt.dart', 'statement.dart'});
      check(cluster.estimatedLinesSaved).equals(2 * cluster.lineCount);
    });

    test('detects structural clones with different literals', () {
      const code1 = '''
void checkLimits(int threshold) {
  if (threshold > 100) {
    print("Warning: limit high: 100");
  } else {
    print("Normal limit: 100");
  }
}
''';

      const code2 = '''
void checkLimits(int threshold) {
  if (threshold > 500) {
    print("Warning: limit high: 500");
  } else {
    print("Normal limit: 500");
  }
}
''';

      const tokenizer = DartTokenizer(ignoreLiterals: true);
      final seq1 = tokenizer.tokenize(filePath: 'limit_a.dart', content: code1);
      final seq2 = tokenizer.tokenize(filePath: 'limit_b.dart', content: code2);

      const detector = CloneDetector(minTokens: 15, minLines: 3);
      final clusters = detector.detect([seq1, seq2]);

      check(clusters.length).equals(1);
      final cluster = clusters.first;
      check(cluster.bucket).equals(CloneBucket.structural);
    });

    test('detects parameterized clones with renamed identifiers', () {
      const code1 = '''
int computeMetric(int alpha, int beta) {
  final sum = alpha + beta;
  final product = alpha * beta;
  return sum + product;
}
''';

      const code2 = '''
int calculateValue(int first, int second) {
  final total = first + second;
  final multiplied = first * second;
  return total + multiplied;
}
''';

      const tokenizer = DartTokenizer(
        ignoreLiterals: true,
        ignoreIdentifiers: true,
      );
      final seq1 = tokenizer.tokenize(filePath: 'math_a.dart', content: code1);
      final seq2 = tokenizer.tokenize(filePath: 'math_b.dart', content: code2);

      const detector = CloneDetector(minTokens: 15, minLines: 3);
      final clusters = detector.detect([seq1, seq2]);

      check(clusters.length).equals(1);
      final cluster = clusters.first;
      check(cluster.bucket).equals(CloneBucket.parameterized);
    });

    test('filters out blocks below minTokens or minLines', () {
      const code1 = 'void a() { int x = 1; }';
      const code2 = 'void a() { int x = 1; }';

      const tokenizer = DartTokenizer();
      final seq1 = tokenizer.tokenize(filePath: 'a.dart', content: code1);
      final seq2 = tokenizer.tokenize(filePath: 'b.dart', content: code2);

      const detector = CloneDetector(minTokens: 40, minLines: 4);
      final clusters = detector.detect([seq1, seq2]);

      check(clusters).isEmpty();
    });
  });
}
