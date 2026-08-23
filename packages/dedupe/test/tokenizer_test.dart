import 'package:checks/checks.dart';
import 'package:dedupe/dedupe.dart';
import 'package:test/test.dart';

void main() {
  group('DartTokenizer', () {
    test(
      'tokenizes simple Dart function and computes line/column locations',
      () {
        const code = '''
void sayHello(String name) {
  print('Hello \$name');
}
''';
        const tokenizer = DartTokenizer();
        final seq = tokenizer.tokenize(filePath: 'test.dart', content: code);

        check(seq.filePath).equals('test.dart');
        check(seq.totalLines).isGreaterThan(2);
        check(seq.tokens).isNotEmpty();

        final first = seq.tokens.first;
        check(first.originalLexeme).equals('void');
        check(first.normalizedLexeme).equals('void');
        check(first.startLine).equals(1);
      },
    );

    test('ignores comments by default', () {
      const code = '''
// Line comment
/* Multi-line
   comment */
void test() {}
/// Doc comment
''';
      const tokenizer = DartTokenizer(ignoreComments: true);
      final seq = tokenizer.tokenize(filePath: 'test.dart', content: code);

      for (final tok in seq.tokens) {
        check(tok.originalLexeme).not((it) => it.startsWith('//'));
        check(tok.originalLexeme).not((it) => it.startsWith('/*'));
      }
    });

    test('extracts comment tokens when ignoreComments is false', () {
      const code = '''
// Leading comment
/// Leading doc comment
void testMethod() {
  // Inner comment
  /* Inner multi-line
     comment */
  print('Hello');
}
// Trailing comment
''';
      const tokenizer = DartTokenizer(ignoreComments: false);
      final seq = tokenizer.tokenize(filePath: 'test.dart', content: code);

      final commentLexemes = seq.tokens
          .where(
            (t) =>
                t.originalLexeme.startsWith('//') ||
                t.originalLexeme.startsWith('/*'),
          )
          .map((t) => t.originalLexeme)
          .toList();

      check(commentLexemes).contains('// Leading comment');
      check(commentLexemes).contains('/// Leading doc comment');
      check(commentLexemes).contains('// Inner comment');
      check(commentLexemes).any((it) => it.startsWith('/* Inner multi-line'));
      check(commentLexemes).contains('// Trailing comment');

      // Verify token ordering and locations
      final firstTok = seq.tokens.first;
      check(firstTok.originalLexeme).equals('// Leading comment');
      check(firstTok.startLine).equals(1);

      final lastTok = seq.tokens.last;
      check(lastTok.originalLexeme).equals('// Trailing comment');
      check(lastTok.startLine).equals(9);
    });

    test(
      'normalizes string and numeric literals when ignoreLiterals is true',
      () {
        const code1 = '''
int compute() {
  final count = 42;
  final msg = "Processing 42 items";
  return count * 100;
}
''';
        const code2 = '''
int compute() {
  final count = 999;
  final msg = "Different string message";
  return count * 500;
}
''';
        const tokenizer = DartTokenizer(ignoreLiterals: true);
        final seq1 = tokenizer.tokenize(filePath: 'a.dart', content: code1);
        final seq2 = tokenizer.tokenize(filePath: 'b.dart', content: code2);

        check(seq1.tokens.length).equals(seq2.tokens.length);

        for (var i = 0; i < seq1.tokens.length; i++) {
          check(
            seq1.tokens[i].normalizedLexeme,
          ).equals(seq2.tokens[i].normalizedLexeme);
        }
      },
    );

    test('normalizes identifiers when ignoreIdentifiers is true', () {
      const code1 = '''
int addNumbers(int alpha, int beta) {
  return alpha + beta;
}
''';
      const code2 = '''
int sumValues(int first, int second) {
  return first + second;
}
''';
      const tokenizer = DartTokenizer(
        ignoreLiterals: true,
        ignoreIdentifiers: true,
      );
      final seq1 = tokenizer.tokenize(filePath: 'a.dart', content: code1);
      final seq2 = tokenizer.tokenize(filePath: 'b.dart', content: code2);

      check(seq1.tokens.length).equals(seq2.tokens.length);

      for (var i = 0; i < seq1.tokens.length; i++) {
        check(
          seq1.tokens[i].normalizedLexeme,
        ).equals(seq2.tokens[i].normalizedLexeme);
      }
    });

    test('extracts snippets by token range and line range', () {
      const code = '''
void first() {
  print('One');
}

void second() {
  print('Two');
}
''';
      const tokenizer = DartTokenizer();
      final seq = tokenizer.tokenize(filePath: 'test.dart', content: code);

      final snippetTokens = seq.getSnippetForTokens(0, 5);
      check(snippetTokens).contains('void first()');

      final lineSnippet = seq.getSnippetForLines(5, 7);
      check(lineSnippet).contains('void second()');
    });
  });
}
