import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/source/line_info.dart';

/// A token normalized for clone detection comparison.
class NormalizedToken {
  final TokenType type;
  final String normalizedLexeme;
  final String originalLexeme;
  final int offset;
  final int length;
  final int startLine;
  final int endLine;
  final int startColumn;
  final int endColumn;
  final int tokenHash;

  int get endOffset => offset + length;

  const NormalizedToken({
    required this.type,
    required this.normalizedLexeme,
    required this.originalLexeme,
    required this.offset,
    required this.length,
    required this.startLine,
    required this.endLine,
    required this.startColumn,
    required this.endColumn,
    required this.tokenHash,
  });

  Map<String, dynamic> toJson() => {
    'type': type.name,
    'normalizedLexeme': normalizedLexeme,
    'originalLexeme': originalLexeme,
    'offset': offset,
    'length': length,
    'startLine': startLine,
    'endLine': endLine,
    'startColumn': startColumn,
    'endColumn': endColumn,
    'tokenHash': tokenHash,
  };

  /// Deserializes a [NormalizedToken] from [json].
  ///
  /// Note: [TokenType] in `pkg:analyzer` is an abstract class with static
  /// instances rather than an enum; [TokenType.IDENTIFIER] is used as the
  /// synthetic token type for deserialized cache entries since clone detection
  /// operates entirely on [normalizedLexeme] and [tokenHash].
  static NormalizedToken fromJson(Map<String, dynamic> json) => NormalizedToken(
    type: TokenType.IDENTIFIER,
    normalizedLexeme: json['normalizedLexeme'] as String,
    originalLexeme: json['originalLexeme'] as String,
    offset: json['offset'] as int,
    length: json['length'] as int,
    startLine: json['startLine'] as int,
    endLine: json['endLine'] as int,
    startColumn: json['startColumn'] as int,
    endColumn: json['endColumn'] as int,
    tokenHash: json['tokenHash'] as int,
  );

  @override
  String toString() => '$normalizedLexeme ($startLine:$startColumn)';
}

/// The complete sequence of normalized tokens extracted from a Dart source
/// file.
class TokenSequence {
  final String filePath;
  final String sourceContent;
  final LineInfo lineInfo;
  final List<NormalizedToken> tokens;
  final int totalLines;

  const TokenSequence({
    required this.filePath,
    required this.sourceContent,
    required this.lineInfo,
    required this.tokens,
    required this.totalLines,
  });

  /// Extracts the source code snippet corresponding to the token range
  /// `[startTokenIndex, endTokenIndex]`.
  String getSnippetForTokens(int startTokenIndex, int endTokenIndex) {
    if (tokens.isEmpty || startTokenIndex >= tokens.length) return '';
    final safeStart = startTokenIndex.clamp(0, tokens.length - 1);
    final safeEnd = endTokenIndex.clamp(safeStart, tokens.length - 1);

    final startOffset = tokens[safeStart].offset;
    final endOffset = tokens[safeEnd].endOffset;

    if (startOffset < 0 ||
        endOffset > sourceContent.length ||
        startOffset >= endOffset) {
      return '';
    }

    return sourceContent.substring(startOffset, endOffset).trim();
  }

  /// Extracts the source code snippet for line range `[startLine, endLine]`.
  String getSnippetForLines(int startLine, int endLine) {
    final lines = sourceContent.split('\n');
    if (lines.isEmpty) return '';
    final safeStart = (startLine - 1).clamp(0, lines.length - 1);
    final safeEnd = (endLine - 1).clamp(safeStart, lines.length - 1);
    return lines.sublist(safeStart, safeEnd + 1).join('\n').trim();
  }
}

/// Tokenizer that converts Dart source code into normalized token streams.
class DartTokenizer {
  final bool ignoreComments;
  final bool ignoreLiterals;
  final bool ignoreIdentifiers;

  const DartTokenizer({
    this.ignoreComments = true,
    this.ignoreLiterals = true,
    this.ignoreIdentifiers = false,
  });

  /// Tokenizes the Dart source [content] of [filePath]. If [tokenOffsetMap] is
  /// provided, maps each token offset to its index in the returned token list.
  TokenSequence tokenize({
    required String filePath,
    required String content,
    Map<int, int>? tokenOffsetMap,
  }) {
    final parseResult = parseString(
      content: content,
      path: filePath,
      throwIfDiagnostics: false,
    );
    final lineInfo = parseResult.lineInfo;
    final tokens = <NormalizedToken>[];

    void processToken(Token t) {
      final (normalized, hash) = _normalizeToken(t);

      final startLoc = lineInfo.getLocation(t.offset);
      final endLoc = lineInfo.getLocation(t.end);

      final idx = tokens.length;
      if (tokenOffsetMap != null) {
        tokenOffsetMap[t.offset] = idx;
      }

      tokens.add(
        NormalizedToken(
          type: t.type,
          normalizedLexeme: normalized,
          originalLexeme: t.lexeme,
          offset: t.offset,
          length: t.length,
          startLine: startLoc.lineNumber,
          endLine: endLoc.lineNumber,
          startColumn: startLoc.columnNumber,
          endColumn: endLoc.columnNumber,
          tokenHash: hash,
        ),
      );
    }

    var token = parseResult.unit.beginToken;

    while (!token.isEof) {
      _processPrecedingComments(token, processToken);
      processToken(token);
      token = token.next!;
    }
    _processPrecedingComments(token, processToken);

    return TokenSequence(
      filePath: filePath,
      sourceContent: content,
      lineInfo: lineInfo,
      tokens: tokens,
      totalLines: lineInfo.lineCount,
    );
  }

  void _processPrecedingComments(
    Token token,
    void Function(Token) processToken,
  ) {
    if (ignoreComments) return;
    var comment = token.precedingComments;
    while (comment != null) {
      processToken(comment);
      final next = comment.next;
      comment = next is CommentToken ? next : null;
    }
  }

  (String, int) _normalizeToken(Token token) {
    if (ignoreLiterals && _isLiteral(token.type)) {
      if (_isStringLiteral(token.type)) {
        return ('<STR>', 0x535452); // '<STR>'.hashCode
      }
      if (_isNumericLiteral(token.type)) {
        return ('<NUM>', 0x4E554D); // '<NUM>'.hashCode
      }
    }

    if (ignoreIdentifiers && token.type == TokenType.IDENTIFIER) {
      return ('<ID>', 0x4944); // '<ID>'.hashCode
    }

    final lexeme = token.lexeme;
    return (lexeme, lexeme.hashCode);
  }

  static bool _isLiteral(TokenType type) =>
      _isStringLiteral(type) || _isNumericLiteral(type);

  static bool _isStringLiteral(TokenType type) =>
      type == TokenType.STRING ||
      type == TokenType.STRING_INTERPOLATION_IDENTIFIER ||
      type == TokenType.STRING_INTERPOLATION_EXPRESSION;

  static bool _isNumericLiteral(TokenType type) =>
      type == TokenType.INT ||
      type == TokenType.HEXADECIMAL ||
      type == TokenType.DOUBLE;
}
