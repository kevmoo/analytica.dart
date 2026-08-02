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
          final normalized = p.normalize(entity.path);
          if (normalized.contains('.dart_tool') ||
              normalized.contains('.git') ||
              normalized.contains('build${p.separator}')) {
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

class _DeclarationFinder extends RecursiveAstVisitor<void> {
  final String filePath;
  final LineInfo lineInfo;
  final results = <FunctionComplexity>[];

  _DeclarationFinder({required this.filePath, required this.lineInfo});

  String? _getEnclosingName(AstNode node) {
    var current = node.parent;
    while (current != null) {
      if (current is ClassDeclaration) {
        return current.namePart.typeName.lexeme;
      }
      if (current is EnumDeclaration) {
        return current.namePart.typeName.lexeme;
      }
      if (current is MixinDeclaration) {
        return current.name.lexeme;
      }
      if (current is ExtensionTypeDeclaration) {
        return current.namePart.typeName.lexeme;
      }
      if (current is ExtensionDeclaration) {
        return current.name?.lexeme ?? '<unnamed extension>';
      }
      current = current.parent;
    }
    return null;
  }

  void _record(String name, AstNode declarationNode, AstNode bodyNode) {
    final visitor = CognitiveComplexityVisitor();
    bodyNode.accept(visitor);

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
    if (node.parent is CompilationUnit && !node.name.type.isKeyword) {
      _record(node.name.lexeme, node, node.functionExpression.body);
    }
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    final rawName = node.name.lexeme;
    final prefix = node.isGetter ? 'get ' : (node.isSetter ? 'set ' : '');
    final enclosing = _getEnclosingName(node);
    final fullName = enclosing != null
        ? '$prefix$enclosing.$rawName'
        : '$prefix$rawName';

    _record(fullName, node, node.body);
  }

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    final enclosing = _getEnclosingName(node) ?? 'Constructor';
    final constName = node.name?.lexeme;
    final fullName = constName == null ? enclosing : '$enclosing.$constName';

    _record(fullName, node, node.body);
  }
}
