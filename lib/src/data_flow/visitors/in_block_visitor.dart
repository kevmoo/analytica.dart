import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/source/line_info.dart';
import '../models.dart';

/// Traverses AST nodes within a target offset slice to detect input parameters,
/// mutations, control flow escapes, and async usage.
class InBlockVisitor extends RecursiveAstVisitor<void> {
  final int sliceStartOffset;
  final int sliceEndOffset;
  final LineInfo lineInfo;

  /// Variables declared before the slice that are read inside the slice.
  final Map<Element, VariableUsage> inputs = {};

  /// Variables declared before the slice that are reassigned inside the slice.
  final Map<Element, VariableUsage> mutations = {};

  /// Variables declared inside the slice.
  final Set<Element> internalDeclarations = {};

  /// Control flow jumps (return, break, continue, yield) within the slice.
  final List<ControlFlowEscape> escapes = [];

  /// Tracks if an `await` expression was encountered within the slice.
  bool hasAwait = false;

  InBlockVisitor({
    required this.sliceStartOffset,
    required this.sliceEndOffset,
    required this.lineInfo,
  });

  bool _isWithinSlice(AstNode node) =>
      node.offset >= sliceStartOffset && node.end <= sliceEndOffset;

  @override
  void visitAwaitExpression(AwaitExpression node) {
    if (_isWithinSlice(node)) {
      hasAwait = true;
    }
    super.visitAwaitExpression(node);
  }

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    if (_isWithinSlice(node)) {
      final element = node.declaredFragment?.element;
      if (element != null) {
        internalDeclarations.add(element);
      }
    }
    super.visitVariableDeclaration(node);
  }

  @override
  void visitDeclaredVariablePattern(DeclaredVariablePattern node) {
    if (_isWithinSlice(node)) {
      final element = node.declaredFragment?.element;
      if (element != null) {
        internalDeclarations.add(element);
      }
    }
    super.visitDeclaredVariablePattern(node);
  }

  @override
  void visitAssignedVariablePattern(AssignedVariablePattern node) {
    if (_isWithinSlice(node)) {
      final element = node.element;
      if (element is VariableElement &&
          element is! FieldElement &&
          element is! TopLevelVariableElement &&
          element is! PropertyInducingElement) {
        final declOffset = _resolveOffset(element);
        final isDeclaredInsideSlice =
            (declOffset >= sliceStartOffset && declOffset <= sliceEndOffset) ||
            internalDeclarations.contains(element);

        if (!isDeclaredInsideSlice && declOffset < sliceStartOffset) {
          final currentLine = lineInfo.getLocation(node.offset).lineNumber;
          final declLine = declOffset >= 0
              ? lineInfo.getLocation(declOffset).lineNumber
              : currentLine;
          final typeName = _resolveTypeName(element);

          mutations[element] = VariableUsage(
            name: element.name ?? node.name.lexeme,
            type: typeName,
            isMutated: true,
            declarationOffset: declOffset,
            declarationLine: declLine,
            firstMutationLine:
                mutations[element]?.firstMutationLine ?? currentLine,
          );
        }
      }
    }
    super.visitAssignedVariablePattern(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (!_isWithinSlice(node)) {
      super.visitSimpleIdentifier(node);
      return;
    }

    final element = node.element;
    if (element is! VariableElement ||
        element is FieldElement ||
        element is TopLevelVariableElement ||
        element is PropertyInducingElement) {
      super.visitSimpleIdentifier(node);
      return;
    }

    if (_isPropertyOrLabel(node)) {
      super.visitSimpleIdentifier(node);
      return;
    }

    // Check if this identifier is the declaration node itself
    if (node.parent is VariableDeclaration) {
      final vd = node.parent as VariableDeclaration;
      if (vd.name == node.token) {
        internalDeclarations.add(element);
        super.visitSimpleIdentifier(node);
        return;
      }
    }

    final declOffset = _resolveOffset(element);
    final isDeclaredInsideSlice =
        (declOffset >= sliceStartOffset && declOffset <= sliceEndOffset) ||
        internalDeclarations.contains(element);

    if (isDeclaredInsideSlice) {
      internalDeclarations.add(element);
      super.visitSimpleIdentifier(node);
      return;
    }

    _recordUsage(declOffset, node, element, isDeclaredInsideSlice);

    super.visitSimpleIdentifier(node);
  }

  int _resolveOffset(Element element) => element.firstFragment.nameOffset ?? -1;

  bool _isPropertyOrLabel(SimpleIdentifier node) {
    final parent = node.parent;
    if (parent is PropertyAccess && parent.propertyName == node) {
      return true;
    }
    if (parent is PrefixedIdentifier && parent.identifier == node) {
      return true;
    }
    if (parent is Label) {
      return true;
    }
    return false;
  }

  void _recordUsage(
    int declOffset,
    SimpleIdentifier node,
    VariableElement element,
    bool isDeclaredInsideSlice,
  ) {
    final isDeclaredBeforeSlice =
        declOffset >= 0 && declOffset < sliceStartOffset;
    final isWrite = node.inSetterContext();
    final isRead = node.inGetterContext();
    final currentLine = lineInfo.getLocation(node.offset).lineNumber;

    final staticType = node.staticType;
    final typeString =
        staticType?.getDisplayString(withNullability: false) ?? '';
    final typeName =
        staticType != null &&
            !staticType.isDartCoreNull &&
            typeString != 'dynamic'
        ? staticType.getDisplayString()
        : _resolveTypeName(element);

    if (isDeclaredBeforeSlice ||
        (!isDeclaredInsideSlice && declOffset < sliceStartOffset)) {
      final declLine = declOffset >= 0
          ? lineInfo.getLocation(declOffset).lineNumber
          : currentLine;

      if (isRead && !inputs.containsKey(element)) {
        inputs[element] = VariableUsage(
          name: element.name ?? node.name,
          type: typeName,
          declarationOffset: declOffset,
          declarationLine: declLine,
        );
      }

      if (isWrite) {
        _addClosureEscapeIfRequired(node, currentLine, typeName);

        final existing = inputs[element];
        inputs[element] =
            (existing ??
                    VariableUsage(
                      name: element.name ?? node.name,
                      type: typeName,
                      declarationOffset: declOffset,
                      declarationLine: declLine,
                    ))
                .copyWith(
                  isMutated: true,
                  firstMutationLine: existing?.firstMutationLine ?? currentLine,
                );

        mutations[element] = VariableUsage(
          name: element.name ?? node.name,
          type: typeName,
          isMutated: true,
          declarationOffset: declOffset,
          declarationLine: declLine,
          firstMutationLine:
              mutations[element]?.firstMutationLine ?? currentLine,
        );
      }
    }
  }

  @override
  void visitReturnStatement(ReturnStatement node) {
    if (_isWithinSlice(node)) {
      if (!_isInsideNestedFunction(node)) {
        escapes.add(
          ControlFlowEscape(
            type: ControlFlowEscapeType.earlyReturn,
            line: lineInfo.getLocation(node.offset).lineNumber,
            description: 'Early return statement alters caller control flow',
          ),
        );
      }
    }
    super.visitReturnStatement(node);
  }

  void _addConstructorInitializerEscape(AstNode node) {
    if (_isWithinSlice(node)) {
      escapes.add(
        ControlFlowEscape(
          type: ControlFlowEscapeType.constructorInitializerEscape,
          line: lineInfo.getLocation(node.offset).lineNumber,
          description: 'Cannot extract constructor initializer expressions',
        ),
      );
    }
  }

  @override
  void visitConstructorFieldInitializer(ConstructorFieldInitializer node) {
    _addConstructorInitializerEscape(node);
    super.visitConstructorFieldInitializer(node);
  }

  @override
  void visitSuperConstructorInvocation(SuperConstructorInvocation node) {
    _addConstructorInitializerEscape(node);
    super.visitSuperConstructorInvocation(node);
  }

  @override
  void visitRedirectingConstructorInvocation(
    RedirectingConstructorInvocation node,
  ) {
    _addConstructorInitializerEscape(node);
    super.visitRedirectingConstructorInvocation(node);
  }

  @override
  void visitAssertInitializer(AssertInitializer node) {
    _addConstructorInitializerEscape(node);
    super.visitAssertInitializer(node);
  }

  @override
  void visitForStatement(ForStatement node) {
    if (_isWithinSlice(node) && node.awaitKeyword != null) {
      hasAwait = true;
    }
    super.visitForStatement(node);
  }

  @override
  void visitRethrowExpression(RethrowExpression node) {
    if (_isWithinSlice(node)) {
      var current = node.parent;
      bool inCatch = false;
      while (current != null) {
        if (current is CatchClause) {
          if (current.offset >= sliceStartOffset) {
            inCatch = true;
          }
          break;
        }
        current = current.parent;
      }
      if (!inCatch) {
        escapes.add(
          ControlFlowEscape(
            type: ControlFlowEscapeType.rethrowEscape,
            line: lineInfo.getLocation(node.offset).lineNumber,
            description:
                'Rethrow statement outside catch clause in extracted slice',
          ),
        );
      }
    }
    super.visitRethrowExpression(node);
  }

  @override
  void visitBreakStatement(BreakStatement node) {
    if (_isWithinSlice(node)) {
      if (node.label != null) {
        final targetOffset = _resolveLabelTargetOffset(node.label!);
        if (targetOffset < sliceStartOffset || targetOffset > sliceEndOffset) {
          escapes.add(
            ControlFlowEscape(
              type: ControlFlowEscapeType.loopBreak,
              line: lineInfo.getLocation(node.offset).lineNumber,
              description:
                  'Break statement targets label outside extracted slice',
            ),
          );
        }
      } else if (!_isEnclosedByBreakableWithinSlice(node)) {
        escapes.add(
          ControlFlowEscape(
            type: ControlFlowEscapeType.loopBreak,
            line: lineInfo.getLocation(node.offset).lineNumber,
            description: 'Break statement targets loop outside extracted slice',
          ),
        );
      }
    }
    super.visitBreakStatement(node);
  }

  @override
  void visitContinueStatement(ContinueStatement node) {
    if (_isWithinSlice(node)) {
      if (node.label != null) {
        final targetOffset = _resolveLabelTargetOffset(node.label!);
        if (targetOffset < sliceStartOffset || targetOffset > sliceEndOffset) {
          escapes.add(
            ControlFlowEscape(
              type: ControlFlowEscapeType.loopContinue,
              line: lineInfo.getLocation(node.offset).lineNumber,
              description:
                  'Continue statement targets label outside extracted slice',
            ),
          );
        }
      } else if (!_isEnclosedByLoopWithinSlice(node)) {
        escapes.add(
          ControlFlowEscape(
            type: ControlFlowEscapeType.loopContinue,
            line: lineInfo.getLocation(node.offset).lineNumber,
            description:
                'Continue statement targets loop outside extracted slice',
          ),
        );
      }
    }
    super.visitContinueStatement(node);
  }

  @override
  void visitYieldStatement(YieldStatement node) {
    if (_isWithinSlice(node)) {
      escapes.add(
        ControlFlowEscape(
          type: ControlFlowEscapeType.yieldEscape,
          line: lineInfo.getLocation(node.offset).lineNumber,
          description: 'Yield statement inside generator',
        ),
      );
    }
    super.visitYieldStatement(node);
  }

  int _resolveLabelTargetOffset(AstNode labelNode) {
    try {
      final String targetName = _extractName(labelNode);
      var current = labelNode.parent;
      while (current != null) {
        if (current is LabeledStatement) {
          for (final l in current.labels) {
            final String lName = _extractName(l);
            if (lName == targetName) {
              return current.offset;
            }
          }
        }
        current = current.parent;
      }
    } catch (_) {}
    return -1;
  }

  String _extractName(dynamic node) {
    try {
      return node.name.lexeme.toString();
    } catch (_) {}
    try {
      return node.name.name.toString();
    } catch (_) {}
    try {
      return node.name.toString();
    } catch (_) {}
    try {
      return node.label.name.toString();
    } catch (_) {}
    return '';
  }

  bool _isInsideNestedFunction(AstNode node) {
    var current = node.parent;
    while (current != null && current.offset >= sliceStartOffset) {
      if (current is FunctionExpression || current is FunctionDeclaration) {
        return true;
      }
      current = current.parent;
    }
    return false;
  }

  void _addClosureEscapeIfRequired(
    AstNode node,
    int currentLine,
    String typeName,
  ) {
    if (_isInsideNestedFunction(node)) {
      escapes.add(
        ControlFlowEscape(
          type: ControlFlowEscapeType.closureEscape,
          line: currentLine,
          description:
              'Variable \$typeName mutated inside a nested function/closure',
        ),
      );
    }
  }

  bool _isEnclosedByBreakableWithinSlice(AstNode node) {
    var current = node.parent;
    while (current != null && current.offset >= sliceStartOffset) {
      if (current is ForStatement ||
          current is WhileStatement ||
          current is DoStatement ||
          current is SwitchStatement) {
        return true;
      }
      current = current.parent;
    }
    return false;
  }

  bool _isEnclosedByLoopWithinSlice(AstNode node) {
    var current = node.parent;
    while (current != null && current.offset >= sliceStartOffset) {
      if (current is ForStatement ||
          current is WhileStatement ||
          current is DoStatement) {
        return true;
      }
      current = current.parent;
    }
    return false;
  }

  String _resolveTypeName(VariableElement element) {
    final type = element.type.getDisplayString();
    return type.isNotEmpty ? type : 'dynamic';
  }
}
