import 'dart:io';
import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:path/path.dart' as p;
import 'cognitive_complexity_visitor.dart';

/// Represents the analyzed cognitive complexity of a specific declaration.
class FunctionComplexity {
  final String filePath;
  final String name;
  final int startLine;
  final int endLine;
  final int score;

  const FunctionComplexity({
    required this.filePath,
    required this.name,
    required this.startLine,
    required this.endLine,
    required this.score,
  });

  Map<String, dynamic> toJson() => {
    'file': filePath,
    'name': name,
    'start_line': startLine,
    'end_line': endLine,
    'score': score,
  };

  @override
  String toString() => '$name ($filePath:L$startLine-$endLine): $score';
}

/// Whether [relativePath] sits inside a directory that should never be
/// scanned (`.dart_tool`, `.git`, or `build` output).
///
/// Matches whole path segments, so `.github/` or `builders/` are not
/// mistaken for `.git/` or `build/`.
bool isExcludedPath(String relativePath) {
  final segments = p.split(p.normalize(relativePath));
  return segments.contains('.dart_tool') ||
      segments.contains('.git') ||
      segments.contains('build');
}

/// Analyzes Dart files and directories to compute Cognitive Complexity scores.
class ComplexityAnalyzer {
  final FeatureSet _featureSet = FeatureSet.latestLanguageVersion();

  /// Analyzes a file or directory at [targetPath].
  List<FunctionComplexity> analyzePath(String targetPath) {
    final file = File(targetPath);
    final dir = Directory(targetPath);

    final results = <FunctionComplexity>[];

    if (file.existsSync()) {
      if (p.extension(targetPath) == '.dart') {
        results.addAll(analyzeFile(targetPath));
      }
    } else if (dir.existsSync()) {
      for (final entity in dir.listSync(recursive: true, followLinks: false)) {
        if (entity is File && p.extension(entity.path) == '.dart') {
          final relative = p.relative(entity.path, from: targetPath);
          if (isExcludedPath(relative)) {
            continue;
          }
          results.addAll(analyzeFile(entity.path));
        }
      }
    } else {
      throw FileSystemException('Path does not exist', targetPath);
    }

    results.sort((a, b) => b.score.compareTo(a.score));
    return results;
  }

  /// Analyzes a single Dart file at [filePath].
  List<FunctionComplexity> analyzeFile(String filePath) {
    try {
      final result = parseFile(
        path: File(filePath).absolute.path,
        featureSet: _featureSet,
        throwIfDiagnostics: false,
      );

      final finder = _DeclarationFinder(
        filePath: filePath,
        lineInfo: result.lineInfo,
      );
      result.unit.accept(finder);
      return finder.results;
    } catch (e) {
      return [];
    }
  }

  /// Analyzes code provided directly as a syntax string [code].
  List<FunctionComplexity> analyzeCode(
    String code, {
    String filePath = '<memory>',
  }) {
    final result = parseString(
      content: code,
      featureSet: _featureSet,
      throwIfDiagnostics: false,
    );
    final finder = _DeclarationFinder(
      filePath: filePath,
      lineInfo: result.lineInfo,
    );
    result.unit.accept(finder);
    return finder.results;
  }
}

String _accessorPrefix({required bool isGetter, required bool isSetter}) {
  if (isGetter) return 'get ';
  if (isSetter) return 'set ';
  return '';
}

class _DeclarationFinder extends RecursiveAstVisitor<void> {
  final String filePath;
  final LineInfo lineInfo;
  final results = <FunctionComplexity>[];

  _DeclarationFinder({required this.filePath, required this.lineInfo});

  static String? _getDeclarationName(AstNode decl) {
    if (decl is ClassDeclaration) {
      return decl.namePart.typeName.lexeme;
    }
    if (decl is EnumDeclaration) {
      return decl.namePart.typeName.lexeme;
    }
    if (decl is MixinDeclaration) {
      return decl.name.lexeme;
    }
    if (decl is ExtensionDeclaration) {
      return decl.name?.lexeme ?? '<unnamed extension>';
    }
    if (decl is ExtensionTypeDeclaration) {
      final d = decl as dynamic;
      try {
        // ignore: avoid_dynamic_calls
        final namePart = d.namePart;
        if (namePart != null) {
          // ignore: avoid_dynamic_calls
          return namePart.typeName.lexeme as String;
        }
      } catch (_) {}

      try {
        // ignore: avoid_dynamic_calls
        final pc = d.primaryConstructor;
        if (pc != null) {
          // ignore: avoid_dynamic_calls
          return pc.beginToken.lexeme as String;
        }
      } catch (_) {}
    }
    return null;
  }

  String? _getEnclosingName(AstNode node) {
    var current = node.parent;
    while (current != null) {
      if (current is ClassDeclaration ||
          current is EnumDeclaration ||
          current is MixinDeclaration ||
          current is ExtensionTypeDeclaration ||
          current is ExtensionDeclaration) {
        return _getDeclarationName(current);
      }
      current = current.parent;
    }
    return null;
  }

  /// Scores [parts] (parameter lists carry default values, constructors
  /// carry initializers) with a single visitor so nothing outside the body
  /// proper is missed.
  void _record(String name, AstNode declarationNode, List<AstNode?> parts) {
    final visitor = CognitiveComplexityVisitor();
    visitor.visitAll(parts);

    final startLoc = lineInfo.getLocation(declarationNode.offset);
    final endLoc = lineInfo.getLocation(declarationNode.end);

    results.add(
      FunctionComplexity(
        filePath: filePath,
        name: name,
        startLine: startLoc.lineNumber,
        endLine: endLoc.lineNumber,
        score: visitor.score,
      ),
    );
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    // Note: pseudo-keywords (`show`, `on`, ...) are legal declaration names
    // and parse with keyword-typed name tokens, so no keyword filtering here.
    if (node.parent is CompilationUnit) {
      final prefix = _accessorPrefix(
        isGetter: node.isGetter,
        isSetter: node.isSetter,
      );
      _record('$prefix${node.name.lexeme}', node, [
        node.functionExpression.parameters,
        node.functionExpression.body,
      ]);
    }
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    final rawName = node.name.lexeme;
    final prefix = _accessorPrefix(
      isGetter: node.isGetter,
      isSetter: node.isSetter,
    );
    final enclosing = _getEnclosingName(node);
    final fullName = enclosing != null
        ? '$prefix$enclosing.$rawName'
        : '$prefix$rawName';

    _record(fullName, node, [node.parameters, node.body]);
  }

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    final enclosing = _getEnclosingName(node) ?? 'Constructor';
    final constName = node.name?.lexeme;
    final fullName = constName == null ? enclosing : '$enclosing.$constName';

    _record(fullName, node, [node.parameters, ...node.initializers, node.body]);
  }
}
