import 'package:analytica/analyzer.dart';
import 'package:analyzer/dart/ast/ast.dart';

/// Helper for parsing custom `// undead:ignore` and `// undead:ignore_for_file`
/// comment suppression directives.
abstract final class CommentParser {
  static final CommentDirectiveParser _parser = CommentDirectiveParser(
    'undead',
  );

  static RegExp get ignoreForFilePattern => _parser.ignoreForFilePattern;
  static RegExp get ignoreDeclarationPattern =>
      _parser.ignoreDeclarationPattern;

  /// Returns `true` if [unit] contains a file-level suppression directive
  /// (`// undead:ignore_for_file`) in its comments.
  static bool hasIgnoreForFile(CompilationUnit unit, [String? sourceCode]) =>
      _parser.hasIgnoreForFile(unit, sourceCode);

  /// Returns `true` if [node] is preceded by a `// undead:ignore` directive.
  static bool isDeclarationIgnored(AstNode node) =>
      _parser.isDeclarationIgnored(node);
}
