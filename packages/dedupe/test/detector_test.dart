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

    test('handles empty input sequences', () {
      const detector = CloneDetector();
      check(detector.detect([])).isEmpty();

      final emptySeq = const DartTokenizer().tokenize(
        filePath: 'empty.dart',
        content: '',
      );
      check(detector.detect([emptySeq])).isEmpty();
    });

    test('detects intra-file duplicate blocks', () {
      const code = '''
void handlerA() {
  print('Step 1: initializing payload');
  print('Step 2: verifying signatures');
  print('Step 3: dispatching event');
  print('Step 4: completing transaction');
}

void handlerB() {
  print('Step 1: initializing payload');
  print('Step 2: verifying signatures');
  print('Step 3: dispatching event');
  print('Step 4: completing transaction');
}
''';
      final seq = const DartTokenizer().tokenize(
        filePath: 'handlers.dart',
        content: code,
      );
      const detector = CloneDetector(minTokens: 15, minLines: 4);
      final clusters = detector.detect([seq]);

      check(clusters.length).equals(1);
      check(clusters.first.instances.length).equals(2);
      check(clusters.first.instances.first.filePath).equals('handlers.dart');
    });

    test('detects and clusters clone groups appearing in >50 locations', () {
      const helperFunction = '''
void auditLogTraceEvent(String eventName, int eventId) {
  print('Audit log event: \$eventName [\$eventId]');
  print('Recording timestamp and thread metadata');
  print('Flushing audit buffer to disk cache');
  print('Verification trace sequence completed');
}
''';

      const tokenizer = DartTokenizer();
      final sequences = <TokenSequence>[];
      for (var i = 0; i < 60; i++) {
        sequences.add(
          tokenizer.tokenize(
            filePath: 'module_$i.dart',
            content: helperFunction,
          ),
        );
      }

      const detector = CloneDetector(minTokens: 15, minLines: 4);
      final clusters = detector.detect(sequences);

      check(clusters.length).equals(1);
      final cluster = clusters.first;
      check(cluster.instances.length).equals(60);
      check(cluster.bucket).equals(CloneBucket.identical);
    });

    test('detects repeated duplicate blocks within the same function', () {
      const code = '''
void executePipelineTasks() {
  {
    final alpha = 100;
    final beta = alpha * 2;
    if (beta > 50) {
      print('Processing batch task alpha');
    }
  }

  for (var i = 0; i < 5; i++) {
    print('Intervening loop: \$i');
  }

  {
    final alpha = 100;
    final beta = alpha * 2;
    if (beta > 50) {
      print('Processing batch task alpha');
    }
  }
}
''';
      final seq = const DartTokenizer().tokenize(
        filePath: 'pipeline.dart',
        content: code,
      );
      const detector = CloneDetector(minTokens: 15, minLines: 4);
      final clusters = detector.detect([seq]);

      check(clusters.length).equals(1);
      final cluster = clusters.first;
      check(cluster.instances.length).equals(2);
      check(cluster.instances[0].filePath).equals('pipeline.dart');
      check(cluster.instances[1].filePath).equals('pipeline.dart');
      check(cluster.bucket).equals(CloneBucket.identical);
    });

    test(
      'deduplicates identical line-range clusters across repeated blocks',
      () {
        const code = '''
void multiBlockSequence() {
  {
    print('Block step 1');
    print('Block step 2');
    print('Block step 3');
    print('Block step 4');
  }
  {
    print('Block step 1');
    print('Block step 2');
    print('Block step 3');
    print('Block step 4');
  }
  {
    print('Block step 1');
    print('Block step 2');
    print('Block step 3');
    print('Block step 4');
  }
}
''';
        final seq = const DartTokenizer().tokenize(
          filePath: 'blocks.dart',
          content: code,
        );
        const detector = CloneDetector(minTokens: 10, minLines: 4);
        final clusters = detector.detect([seq]);

        final signatures = <String>{};
        for (final c in clusters) {
          final sig = c.instances
              .map((i) => '${i.filePath}:${i.startLine}-${i.endLine}')
              .join(';');
          check(signatures.add(sig)).isTrue();
        }
      },
    );
  });
}
