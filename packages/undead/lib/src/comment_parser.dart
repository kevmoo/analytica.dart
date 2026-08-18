import 'package:analytica/analyzer.dart';
import 'package:analyzer/dart/ast/ast.dart';

/// Helper for parsing custom `// undead:ignore` and `// undead:ignore_for_file`
/// comment suppression directives.
abstract final class CommentParser {
  static final CommentDirectiveParser _undeadParser = CommentDirectiveParser(
    'undead',
  );
  static final CommentDirectiveParser _zombieParser = CommentDirectiveParser(
    'zombie',
  );

  static RegExp get ignoreForFilePattern => _undeadParser.ignoreForFilePattern;
  static RegExp get ignoreDeclarationPattern =>
      _undeadParser.ignoreDeclarationPattern;

  /// Returns `true` if [unit] contains a file-level suppression directive
  /// (`// undead:ignore_for_file` or `// zombie:ignore_for_file`) in its comments.
  static bool hasIgnoreForFile(CompilationUnit unit, [String? sourceCode]) =>
      _undeadParser.hasIgnoreForFile(unit, sourceCode) ||
      _zombieParser.hasIgnoreForFile(unit, sourceCode);

  /// Returns `true` if [node] is preceded by a `// undead:ignore` or
  /// `// zombie:ignore` directive.
  static bool isDeclarationIgnored(AstNode node) =>
      _undeadParser.isDeclarationIgnored(node) ||
      _zombieParser.isDeclarationIgnored(node);
}
