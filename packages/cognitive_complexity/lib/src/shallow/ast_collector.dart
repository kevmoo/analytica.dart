import 'dart:math' as math;

import 'package:analytica/analyzer.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:path/path.dart' as p;

import '../complexity/cognitive_complexity_visitor.dart';

final shallowDirectiveParser = CommentDirectiveParser('cognitive_complexity');

/// Internal AST representation of a candidate declaration in `ShallowAnalyzer`.
class ShallowDeclNode {
  final String filePath;
  final String normalizedFilePath;
  final String? enclosingType;
  final String rawName;
  final int startLine;
  final int endLine;
  final int signatureLines;
  final int bodyLines;
  final int parameterCount;
  final int namedParameterCount;

  /// Number of top-level statements in the body (`1` for `=>` bodies), plus
  /// `max(0, armCount - 1)` for each multi-arm `switch` expression or
  /// statement (excluding nested functions).
  final int statementCount;

  /// [parameterCount] with record-typed parameters expanded to their field
  /// count, so packing values into an inline record cannot hide arity.
  final int effectiveParameterCount;

  /// Declared parameter names in declaration order.
  final List<String> parameterNames;
  final bool isPrivate;
  final bool isStatic;
  final bool isExempt;
  final bool isInRequestedTargets;
  final AstNode node;
  final List<AstNode?> ccParts;
  final Set<String> referencedPrivateNames = {};
  late final int score = scoreAstParts(ccParts);

  ShallowDeclNode({
    required this.filePath,
    required this.normalizedFilePath,
    required this.enclosingType,
    required this.rawName,
    required this.startLine,
    required this.endLine,
    required this.signatureLines,
    required this.bodyLines,
    required this.parameterCount,
    required this.namedParameterCount,
    required this.statementCount,
    required this.effectiveParameterCount,
    required this.parameterNames,
    required this.isPrivate,
    required this.isStatic,
    required this.isExempt,
    required this.isInRequestedTargets,
    required this.node,
    required this.ccParts,
  });

  String get qualifiedName =>
      enclosingType != null ? '$enclosingType.$rawName' : rawName;

  int get lineCount => endLine >= startLine ? endLine - startLine + 1 : 0;
}

/// Counts the statements directly inside [body] (`1` for expression bodies),
/// plus `max(0, armCount - 1)` for each multi-arm `switch` expression or
/// `switch` statement inside [body] (stopping at nested function boundaries).
int countBodyStatements(FunctionBody body) {
  final base = switch (body) {
    BlockFunctionBody(:final block) => block.statements.length,
    ExpressionFunctionBody() => 1,
    _ => 0,
  };
  if (base == 0) return 0;
  final counter = _SwitchArmCounter();
  body.accept(counter);
  return base + counter.extraStatements;
}

class _SwitchArmCounter extends RecursiveAstVisitor<void> {
  int extraStatements = 0;

  @override
  void visitSwitchExpression(SwitchExpression node) {
    extraStatements += math.max(0, node.cases.length - 1);
    super.visitSwitchExpression(node);
  }

  @override
  void visitSwitchStatement(SwitchStatement node) {
    final armCount = node.members.where((m) => m.statements.isNotEmpty).length;
    extraStatements += math.max(0, armCount - 1);
    super.visitSwitchStatement(node);
  }

  @override
  void visitFunctionExpression(FunctionExpression node) {}

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {}
}

/// Counts [parameters] with record-typed parameters expanded to their field
/// count.
int countEffectiveParameters(Iterable<FormalParameter> parameters) {
  var count = 0;
  for (final param in parameters) {
    final type = _typeAnnotationOf(param);
    count += type is RecordTypeAnnotation
        ? math.max(
            1,
            type.positionalFields.length +
                (type.namedFields?.fields.length ?? 0),
          )
        : 1;
  }
  return count;
}

/// Returns the declared type annotation of [param], if any.
///
/// Walks `childEntities` rather than matching concrete node classes because
/// the parameter node hierarchy differs across the supported `analyzer` range
/// (`DefaultFormalParameter` wraps the parameter before 13.0.0).
TypeAnnotation? _typeAnnotationOf(FormalParameter param) {
  for (final child in param.childEntities) {
    if (child is TypeAnnotation) return child;
    if (child is FormalParameter) return _typeAnnotationOf(child);
  }
  return null;
}

/// Internal AST representation of a function or method call / tear-off site.
class ShallowCallSite {
  final ShallowDeclNode? caller;
  final String filePath;
  final String normalizedFilePath;
  final int line;
  final String calleeName;
  final int nestingDepth;
  final bool isTestFile;
  final bool isTearOff;

  /// Whether the call has an explicit receiver other than `this`
  /// (`other.parse()`), so it may target a different declaration.
  final bool isQualified;

  const ShallowCallSite({
    required this.caller,
    required this.filePath,
    required this.normalizedFilePath,
    required this.line,
    required this.calleeName,
    required this.nestingDepth,
    required this.isTestFile,
    required this.isTearOff,
    this.isQualified = false,
  });
}

/// Extracts conditional import/export target paths (normalized relative paths)
/// from [directives] in [filePath].
void collectConditionalDirectiveFiles({
  required List<Directive> directives,
  required String filePath,
  required Set<String> conditionalFiles,
}) {
  final baseDir = p.dirname(filePath);
  for (final directive in directives) {
    if (directive is! NamespaceDirective || directive.configurations.isEmpty) {
      continue;
    }
    final defaultUri = directive.uri.stringValue;
    if (defaultUri != null && _isRelativeUri(defaultUri)) {
      conditionalFiles.add(p.normalize(p.join(baseDir, defaultUri)));
    }
    for (final config in directive.configurations) {
      final uri = config.uri.stringValue;
      if (uri != null && _isRelativeUri(uri)) {
        conditionalFiles.add(p.normalize(p.join(baseDir, uri)));
      }
    }
  }
}

/// Tracks which files and symbols are re-exported by public library
/// entrypoints.
class ExportedSurfaceTracker {
  /// Files where all public symbols are exported (or with specific hidden
  /// names).
  final Map<String, Set<String>> exportedFilesHiddenNames = {};

  /// Files where only specific `show` combinator names are exported.
  final Map<String, Set<String>> exportedFilesShownNames = {};

  void recordExportDirectives({
    required List<Directive> directives,
    required String filePath,
  }) {
    final baseDir = p.dirname(filePath);
    for (final directive in directives.whereType<ExportDirective>()) {
      final uri = directive.uri.stringValue;
      if (uri == null || !_isRelativeUri(uri)) continue;
      final targetNorm = p.normalize(p.join(baseDir, uri));
      _recordCombinators(targetNorm, directive.combinators);
    }
  }

  void _recordCombinators(String targetNorm, NodeList<Combinator> combinators) {
    final shown = <String>{};
    final hidden = <String>{};
    for (final comb in combinators) {
      if (comb is ShowCombinator) {
        shown.addAll(comb.shownNames.map((id) => id.name));
      } else if (comb is HideCombinator) {
        hidden.addAll(comb.hiddenNames.map((id) => id.name));
      }
    }
    if (shown.isNotEmpty) {
      exportedFilesShownNames.putIfAbsent(targetNorm, () => {}).addAll(shown);
    } else {
      exportedFilesHiddenNames.putIfAbsent(targetNorm, () => {}).addAll(hidden);
    }
  }

  bool isPubliclyExported({
    required String normalizedFilePath,
    required String topLevelSymbolName,
    required bool isPublicEntryFile,
  }) {
    if (topLevelSymbolName.startsWith('_')) return false;
    if (isPublicEntryFile) return true;
    final hidden = exportedFilesHiddenNames[normalizedFilePath];
    if (hidden != null && !hidden.contains(topLevelSymbolName)) {
      return true;
    }
    final shown = exportedFilesShownNames[normalizedFilePath];
    return shown != null && shown.contains(topLevelSymbolName);
  }
}

bool _isRelativeUri(String uri) =>
    uri.isNotEmpty && !uri.startsWith('dart:') && !uri.startsWith('package:');

/// Collects declarations and call/tear-off sites within a single file.
class ShallowFileCollector extends RecursiveAstVisitor<void> {
  final String filePath;
  final String normalizedFilePath;
  final LineInfo lineInfo;
  final bool isTestFile;
  final bool isPublicEntryFile;
  final bool isConditionalFile;
  final bool isInRequestedTargets;
  final ExportedSurfaceTracker exportTracker;

  final List<ShallowDeclNode> declarations = [];
  final List<ShallowCallSite> calls = [];

  /// Instance field names declared by each class, mixin, enum, or extension
  /// type in this file, keyed by type name.
  final Map<String, Set<String>> fieldNamesByType = {};

  ShallowDeclNode? _currentDecl;

  ShallowFileCollector({
    required this.filePath,
    required this.normalizedFilePath,
    required this.lineInfo,
    required this.isTestFile,
    required this.isPublicEntryFile,
    required this.isConditionalFile,
    required this.isInRequestedTargets,
    required this.exportTracker,
  });

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    if (node.parent is! CompilationUnit || node.isGetter || node.isSetter) {
      super.visitFunctionDeclaration(node);
      return;
    }
    final body = node.functionExpression.body;
    final params = node.functionExpression.parameters;
    final rawName = node.name.lexeme;
    final decl = _createDeclNode(
      rawName: rawName,
      enclosingType: null,
      topLevelSymbol: rawName,
      node: node,
      params: params,
      body: body,
      isStatic: false,
      isAdditionalExempt:
          body is EmptyFunctionBody || node.externalKeyword != null,
    );
    declarations.add(decl);
    _visitInsideDecl(decl, () => super.visitFunctionDeclaration(node));
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    if (node.isGetter ||
        node.isSetter ||
        node.isOperator ||
        node.externalKeyword != null ||
        node.body is EmptyFunctionBody) {
      super.visitMethodDeclaration(node);
      return;
    }
    final enclosing = _enclosingTypeName(node);
    final rawName = node.name.lexeme;
    final isBuild =
        rawName == 'build' &&
        (node.parameters?.parameters.any(
              (p) => p.toSource().contains('BuildContext'),
            ) ??
            false);
    final decl = _createDeclNode(
      rawName: rawName,
      enclosingType: enclosing,
      topLevelSymbol: enclosing ?? rawName,
      node: node,
      params: node.parameters,
      body: node.body,
      isStatic: node.isStatic,
      isAdditionalExempt: isBuild,
    );
    declarations.add(decl);
    _visitInsideDecl(decl, () => super.visitMethodDeclaration(node));
  }

  @override
  void visitFieldDeclaration(FieldDeclaration node) {
    final enclosing = _enclosingTypeName(node);
    if (!node.isStatic && enclosing != null) {
      fieldNamesByType
          .putIfAbsent(enclosing, () => {})
          .addAll(node.fields.variables.map((v) => v.name.lexeme));
    }
    super.visitFieldDeclaration(node);
  }

  void _visitInsideDecl(ShallowDeclNode decl, void Function() visitChildren) {
    final prev = _currentDecl;
    _currentDecl = decl;
    visitChildren();
    _currentDecl = prev;
  }

  ShallowDeclNode _createDeclNode({
    required String rawName,
    required String? enclosingType,
    required String topLevelSymbol,
    required AnnotatedNode node,
    required FormalParameterList? params,
    required FunctionBody body,
    required bool isStatic,
    required bool isAdditionalExempt,
  }) {
    final startLine = lineInfo.getLocation(node.offset).lineNumber;
    final endLine = lineInfo.getLocation(node.end).lineNumber;
    final bodyStartLine = lineInfo.getLocation(body.offset).lineNumber;
    final sigLines = (bodyStartLine - startLine + 1).clamp(1, 500);
    final bodyLines = (endLine - bodyStartLine + 1).clamp(1, 100000);
    final paramList = params?.parameters ?? const <FormalParameter>[];
    final namedCount = paramList.where((p) => p.isNamed).length;
    final isPrivate =
        rawName.startsWith('_') ||
        (enclosingType != null &&
            (enclosingType.startsWith('_') || enclosingType.startsWith('<')));
    final isPublicApi =
        !isPrivate &&
        exportTracker.isPubliclyExported(
          normalizedFilePath: normalizedFilePath,
          topLevelSymbolName: topLevelSymbol,
          isPublicEntryFile: isPublicEntryFile,
        );
    final isExempt =
        isAdditionalExempt ||
        isConditionalFile ||
        isPublicApi ||
        rawName == 'main' ||
        rawName.startsWith('visit') ||
        hasAnnotation(node, 'override') ||
        isTestSupportDeclaration(node, rawName) ||
        isNativeOrEntryPoint(node) ||
        shallowDirectiveParser.isDeclarationIgnored(node);

    return ShallowDeclNode(
      filePath: filePath,
      normalizedFilePath: normalizedFilePath,
      enclosingType: enclosingType,
      rawName: rawName,
      startLine: startLine,
      endLine: endLine,
      signatureLines: sigLines,
      bodyLines: bodyLines,
      parameterCount: paramList.length,
      namedParameterCount: namedCount,
      statementCount: countBodyStatements(body),
      effectiveParameterCount: countEffectiveParameters(paramList),
      parameterNames: [
        for (final param in paramList)
          if (param.name case final name?) name.lexeme,
      ],
      isPrivate: isPrivate,
      isStatic: isStatic,
      isExempt: isExempt,
      isInRequestedTargets: isInRequestedTargets,
      node: node,
      ccParts: [params, body],
    );
  }

  String? _enclosingTypeName(AstNode node) {
    var cur = node.parent;
    while (cur != null) {
      if (cur is ExtensionDeclaration) {
        return extractNodeName(cur) ??
            '<extension on '
                '${cur.onClause?.extendedType.toSource() ?? 'dynamic'}>';
      }
      if (cur is ClassDeclaration ||
          cur is EnumDeclaration ||
          cur is MixinDeclaration ||
          cur is ExtensionTypeDeclaration) {
        return extractNodeName(cur);
      }
      cur = cur.parent;
    }
    return null;
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    _recordCallSite(
      node,
      node.methodName.name,
      isTearOff: false,
      isQualified: switch (node.realTarget) {
        null || ThisExpression() => false,
        _ => true,
      },
    );
    super.visitMethodInvocation(node);
  }

  @override
  void visitNamedType(NamedType node) {
    final cur = _currentDecl;
    final typeName = node.name.lexeme;
    if (cur != null && typeName.startsWith('_')) {
      cur.referencedPrivateNames.add(typeName);
    }
    super.visitNamedType(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    final cur = _currentDecl;
    if (cur != null && node.name.startsWith('_') && node.name != cur.rawName) {
      cur.referencedPrivateNames.add(node.name);
    }
    if (_isTearOffContext(node)) {
      _recordCallSite(node, node.name, isTearOff: true);
    }
    super.visitSimpleIdentifier(node);
  }

  void _recordCallSite(
    AstNode siteNode,
    String calleeName, {
    required bool isTearOff,
    bool isQualified = false,
  }) {
    final caller = _currentDecl;
    final depth = caller != null ? nestingDepthAt(siteNode, caller.node) : 0;
    calls.add(
      ShallowCallSite(
        caller: caller,
        filePath: filePath,
        normalizedFilePath: normalizedFilePath,
        line: lineInfo.getLocation(siteNode.offset).lineNumber,
        calleeName: calleeName,
        nestingDepth: depth,
        isTestFile: isTestFile,
        isTearOff: isTearOff,
        isQualified: isQualified,
      ),
    );
  }

  bool _isTearOffContext(SimpleIdentifier node) {
    final parent = node.parent;
    if (parent == null || parent is Label) return false;
    if (_isInvocationOrPrefixTarget(node, parent)) return false;
    final expr = _unwrapQualifiedTearOff(node, parent);
    final context = switch (expr.parent) {
      NamedArgument(:final argumentExpression, :final parent)
          when identical(argumentExpression, expr) =>
        parent,
      final p => p,
    };
    return switch (context) {
      ArgumentList() ||
      ReturnStatement() ||
      ExpressionFunctionBody() ||
      ListLiteral() ||
      SetOrMapLiteral() ||
      SwitchExpressionCase() => true,
      VariableDeclaration(:final initializer) => identical(initializer, expr),
      AssignmentExpression(:final rightHandSide) => identical(
        rightHandSide,
        expr,
      ),
      _ => false,
    };
  }

  bool _isInvocationOrPrefixTarget(SimpleIdentifier node, AstNode parent) =>
      (parent is MethodInvocation && identical(parent.methodName, node)) ||
      (parent is PropertyAccess && identical(parent.target, node)) ||
      (parent is PrefixedIdentifier && identical(parent.prefix, node));

  AstNode _unwrapQualifiedTearOff(SimpleIdentifier node, AstNode parent) {
    if ((parent is PrefixedIdentifier && identical(parent.identifier, node)) ||
        (parent is PropertyAccess && identical(parent.propertyName, node))) {
      return parent;
    }
    return node;
  }
}
