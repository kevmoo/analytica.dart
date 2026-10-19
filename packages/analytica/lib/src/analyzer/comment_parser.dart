import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';

/// Generic token-based suppression parser for `// <tool>:ignore` and
/// `// <tool>:ignore_for_file` comment suppression directives.
///
/// Because this parser inspects token stream comments rather than raw string
/// matching, it is completely immune to false positives inside string literals.
class CommentDirectiveParser {
  final String toolName;
  final RegExp ignoreForFilePattern;
  final RegExp ignoreDeclarationPattern;

  CommentDirectiveParser(this.toolName)
    : ignoreForFilePattern = RegExp(
        '//\\s*${RegExp.escape(toolName)}:ignore_for_file\\b',
      ),
      ignoreDeclarationPattern = RegExp(
        '//\\s*${RegExp.escape(toolName)}:ignore\\b(.*)\$',
      );

  static final _leadingReasonSeparator = RegExp(r'^[\s:\-]+');

  /// Returns `true` if [unit] contains a file-level suppression directive
  /// (`// <tool>:ignore_for_file`) in its comments.
  bool hasIgnoreForFile(CompilationUnit unit, [String? sourceCode]) {
    var token = unit.beginToken;
    while (true) {
      Token? comment = token.precedingComments;
      while (comment != null) {
        if (ignoreForFilePattern.hasMatch(comment.lexeme)) {
          return true;
        }
        comment = comment.next;
      }
      if (token.isEof) break;
      final nextToken = token.next;
      if (nextToken == null) break;
      token = nextToken;
    }
    return false;
  }

  /// Returns `true` if [node] is preceded by a `// <tool>:ignore` directive.
  bool isDeclarationIgnored(AstNode node) =>
      _findDeclarationIgnore(node).ignored;

  /// Returns the optional suppression reason following `// <tool>:ignore` on
  /// [node] (stripping leading `:`, `-`, `--`, and whitespace), or `null` if
  /// [node] is not ignored or no reason text was provided.
  String? declarationIgnoreReason(AstNode node) =>
      _findDeclarationIgnore(node).reason;

  ({bool ignored, String? reason}) _findDeclarationIgnore(AstNode node) {
    // Check comments preceding the beginToken.
    final beginMatch = _matchIgnoreInComments(
      node.beginToken.precedingComments,
    );
    if (beginMatch.ignored) return beginMatch;

    // If node is an annotated node, also check comments on each metadata token
    // and the first token after metadata.
    if (node is AnnotatedNode) {
      for (final meta in node.metadata) {
        final metaMatch = _matchIgnoreInComments(
          meta.beginToken.precedingComments,
        );
        if (metaMatch.ignored) return metaMatch;
      }
      final firstToken = node.firstTokenAfterCommentAndMetadata;
      final afterMetaMatch = _matchIgnoreInComments(
        firstToken.precedingComments,
      );
      if (afterMetaMatch.ignored) return afterMetaMatch;
    }

    // If node is a VariableDeclaration inside a VariableDeclarationList,
    // also check the enclosing AnnotatedNode (TopLevelVariableDeclaration or
    // FieldDeclaration).
    if (node.parent case VariableDeclarationList(
      parent: final AnnotatedNode grandParent,
    )) {
      return _findDeclarationIgnore(grandParent);
    }

    return (ignored: false, reason: null);
  }

  ({bool ignored, String? reason}) _matchIgnoreInComments(Token? commentToken) {
    var current = commentToken;
    while (current != null) {
      final match = ignoreDeclarationPattern.firstMatch(current.lexeme);
      if (match != null) {
        final raw = match.group(1) ?? '';
        final cleaned = raw.replaceFirst(_leadingReasonSeparator, '').trim();
        return (ignored: true, reason: cleaned.isEmpty ? null : cleaned);
      }
      current = current.next;
    }
    return (ignored: false, reason: null);
  }

  /// Static helper to check file-level suppression for a given [toolName].
  static bool hasIgnoreForFileDirective(
    CompilationUnit unit, {
    required String toolName,
    String? sourceCode,
  }) => CommentDirectiveParser(toolName).hasIgnoreForFile(unit, sourceCode);

  /// Static helper to check declaration-level suppression for a given
  /// [toolName].
  static bool isDeclarationIgnoredFor(
    AstNode node, {
    required String toolName,
  }) => CommentDirectiveParser(toolName).isDeclarationIgnored(node);

  /// Static helper to extract the optional suppression reason following
  /// `// <tool>:ignore` on [node] for a given [toolName].
  static String? declarationIgnoreReasonFor(
    AstNode node, {
    required String toolName,
  }) => CommentDirectiveParser(toolName).declarationIgnoreReason(node);
}
