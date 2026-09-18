import 'dart:io';
import 'package:analytica/analyzer.dart';
import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:path/path.dart' as p;
import 'cognitive_complexity_visitor.dart';

export 'package:analytica/analyzer.dart' show PathFilter, isExcludedPath;

final _directiveParser = CommentDirectiveParser('cognitive_complexity');

/// Represents the total physical line count of a Dart source file.
class FileLineMetric {
  final String filePath;
  final int lineCount;

  const FileLineMetric({required this.filePath, required this.lineCount});

  bool isViolation({int? maxFileLines}) =>
      maxFileLines != null && maxFileLines > 0 && lineCount > maxFileLines;

  Map<String, dynamic> toJson({int? maxFileLines}) => {
    'file': filePath,
    'lines': lineCount,
    if (maxFileLines != null && maxFileLines > 0)
      'violation': isViolation(maxFileLines: maxFileLines),
  };

  @override
  String toString() => '$filePath ($lineCount lines)';
}

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

  /// Total physical line span of this declaration (`endLine - startLine + 1`).
  int get lineCount => endLine >= startLine ? endLine - startLine + 1 : 0;

  /// Whether this declaration violates either [failThreshold] (score) or
  /// [maxFunctionLines] (opt-in declaration line count).
  bool isViolation({int? failThreshold, int? maxFunctionLines}) =>
      (failThreshold != null && score > failThreshold) ||
      (maxFunctionLines != null &&
          maxFunctionLines > 0 &&
          lineCount > maxFunctionLines);

  Map<String, dynamic> toJson() => {
    'file': filePath,
    'name': name,
    'start_line': startLine,
    'end_line': endLine,
    'lines': lineCount,
    'score': score,
  };

  @override
  String toString() => '$name ($filePath:L$startLine-$endLine): $score';
}

/// Analyzes Dart files and directories to compute Cognitive Complexity scores
/// and optional file/declaration line counts.
class ComplexityAnalyzer {
  final PathFilter pathFilter;
  final FeatureSet _featureSet = FeatureSet.latestLanguageVersion();

  ComplexityAnalyzer({PathFilter? pathFilter})
    : pathFilter = pathFilter ?? PathFilter.defaults;

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
      results.addAll(_analyzeDirectory(dir, targetPath));
    } else {
      throw FileSystemException('Path does not exist', targetPath);
    }

    results.sort((a, b) => b.score.compareTo(a.score));
    return results;
  }

  /// Analyzes total line counts for all non-excluded `.dart` files under
  /// [targetPath].
  List<FileLineMetric> analyzePathFileLines(String targetPath) {
    final file = File(targetPath);
    final dir = Directory(targetPath);
    final metrics = <FileLineMetric>[];

    if (file.existsSync()) {
      if (p.extension(targetPath) == '.dart') {
        final metric = analyzeFileLineCount(targetPath);
        if (metric != null) metrics.add(metric);
      }
    } else if (dir.existsSync()) {
      for (final entity in dir.listSync(recursive: true, followLinks: false)) {
        if (entity is File && p.extension(entity.path) == '.dart') {
          final relative = p.relative(entity.path, from: targetPath);
          if (pathFilter.isExcluded(relative)) continue;
          final metric = analyzeFileLineCount(entity.path);
          if (metric != null) metrics.add(metric);
        }
      }
    } else {
      throw FileSystemException('Path does not exist', targetPath);
    }

    metrics.sort((a, b) => b.lineCount.compareTo(a.lineCount));
    return metrics;
  }

  /// Computes the [FileLineMetric] for [filePath], or returns `null` if the
  /// file carries a `// cognitive_complexity:ignore_for_file` directive.
  FileLineMetric? analyzeFileLineCount(String filePath) {
    try {
      final result = parseFile(
        path: File(filePath).absolute.path,
        featureSet: _featureSet,
        throwIfDiagnostics: false,
      );
      if (_directiveParser.hasIgnoreForFile(result.unit)) {
        return null;
      }
      return FileLineMetric(
        filePath: filePath,
        lineCount: result.lineInfo.lineCount,
      );
    } catch (_) {
      return null;
    }
  }

  /// Computes the total physical line count of [code], returning `0` for empty
  /// content or `null` if suppressed via
  /// `// cognitive_complexity:ignore_for_file`.
  int? analyzeCodeLineCount(String code) {
    if (code.trim().isEmpty) return 0;
    final result = parseString(
      content: code,
      featureSet: _featureSet,
      throwIfDiagnostics: false,
    );
    if (_directiveParser.hasIgnoreForFile(result.unit)) {
      return null;
    }
    return result.lineInfo.lineCount;
  }

  List<FunctionComplexity> _analyzeDirectory(Directory dir, String targetPath) {
    final results = <FunctionComplexity>[];
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is File && p.extension(entity.path) == '.dart') {
        final relative = p.relative(entity.path, from: targetPath);
        if (pathFilter.isExcluded(relative)) {
          continue;
        }
        results.addAll(analyzeFile(entity.path));
      }
    }
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
      if (_directiveParser.hasIgnoreForFile(result.unit)) {
        return [];
      }

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
    if (_directiveParser.hasIgnoreForFile(result.unit)) {
      return [];
    }
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

  String? _getEnclosingName(AstNode node) {
    var current = node.parent;
    while (current != null) {
      if (current is ClassDeclaration ||
          current is EnumDeclaration ||
          current is MixinDeclaration ||
          current is ExtensionTypeDeclaration ||
          current is ExtensionDeclaration) {
        return extractNodeName(current);
      }
      current = current.parent;
    }
    return null;
  }

  /// Scores [parts] (parameter lists carry default values, constructors
  /// carry initializers) with a single visitor so nothing outside the body
  /// proper is missed.
  void _record(String name, AstNode declarationNode, List<AstNode?> parts) {
    if (_directiveParser.isDeclarationIgnored(declarationNode)) {
      return;
    }
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
