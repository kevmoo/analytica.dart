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
    final typeName = _resolveTypeName(element);

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

  @override
  void visitBreakStatement(BreakStatement node) {
    if (_isWithinSlice(node)) {
      if (!_isEnclosedByBreakableWithinSlice(node)) {
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
      if (!_isEnclosedByLoopWithinSlice(node)) {
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
