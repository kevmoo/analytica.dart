import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/source/line_info.dart';
import '../models.dart';

/// Traverses AST nodes after the target slice (up to the enclosing function
/// end) to detect which internally created or mutated variables remain live.
class PostBlockVisitor extends RecursiveAstVisitor<void> {
  final int sliceStartOffset;
  final int sliceEndOffset;
  final LineInfo lineInfo;
  final Set<Element> internalDeclarations;
  final Map<Element, VariableUsage> mutations;

  /// Source spans of loops that fully enclose the slice. A read anywhere
  /// inside such a loop is reachable from the slice via the loop's back edge.
  /// A declaration at an offset below `carryBoundary` survives the back edge;
  /// bindings declared at or past it are re-created each iteration.
  final List<({int offset, int end, int carryBoundary})> enclosingLoopSpans;

  /// Variables that are live after the block and must be returned.
  final Map<Element, VariableUsage> liveOutputs = {};

  PostBlockVisitor({
    required this.sliceStartOffset,
    required this.sliceEndOffset,
    required this.lineInfo,
    required this.internalDeclarations,
    required this.mutations,
    this.enclosingLoopSpans = const [],
  });

  bool _isAfterSlice(AstNode node) => node.offset > sliceEndOffset;

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (!_isAfterSlice(node)) {
      _maybeRecordLoopCarriedRead(node);
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

    final isRead = node.inGetterContext();
    if (!isRead) {
      super.visitSimpleIdentifier(node);
      return;
    }

    _recordLiveOutput(element, node);

    super.visitSimpleIdentifier(node);
  }

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

  void _recordLiveOutput(VariableElement element, SimpleIdentifier node) {
    final declOffset = _resolveOffset(element);
    final typeName = _resolveTypeName(element);
    final currentLine = lineInfo.getLocation(node.offset).lineNumber;
    final declLine = declOffset >= 0
        ? lineInfo.getLocation(declOffset).lineNumber
        : currentLine;

    // Case 1: Declared inside target slice and read afterwards.
    if (internalDeclarations.contains(element) ||
        (declOffset >= sliceStartOffset && declOffset <= sliceEndOffset)) {
      if (!liveOutputs.containsKey(element)) {
        liveOutputs[element] = VariableUsage(
          name: element.name ?? node.name,
          type: typeName,
          declarationOffset: declOffset,
          declarationLine: declLine,
        );
      }
    }

    // Case 2: Declared before target slice, mutated in slice, and read
    // afterwards.
    if (mutations.containsKey(element)) {
      if (!liveOutputs.containsKey(element)) {
        _recordMutatedOutput(element, node, declOffset);
      }
    }
  }

  /// A read inside an enclosing loop is downstream of the slice via the
  /// loop's back edge, so a variable the slice mutates stays live even when
  /// the read sits textually before the slice — provided the declaration
  /// predates the loop (a binding declared inside the loop is re-created
  /// each iteration and cannot carry the slice's write backwards).
  void _maybeRecordLoopCarriedRead(SimpleIdentifier node) {
    final element = node.element;
    if (element is! VariableElement || !mutations.containsKey(element)) {
      return;
    }
    if (liveOutputs.containsKey(element)) return;
    if (_isPropertyOrLabel(node) || !node.inGetterContext()) return;

    final declOffset = _resolveOffset(element);
    for (final loop in enclosingLoopSpans) {
      if (node.offset >= loop.offset &&
          node.end <= loop.end &&
          declOffset >= 0 &&
          declOffset < loop.carryBoundary) {
        _recordMutatedOutput(element, node, declOffset);
        return;
      }
    }
  }

  void _recordMutatedOutput(
    VariableElement element,
    SimpleIdentifier node,
    int declOffset,
  ) {
    final currentLine = lineInfo.getLocation(node.offset).lineNumber;
    final declLine = declOffset >= 0
        ? lineInfo.getLocation(declOffset).lineNumber
        : currentLine;
    liveOutputs[element] = VariableUsage(
      name: element.name ?? node.name,
      type: _resolveTypeName(element),
      isMutated: true,
      declarationOffset: declOffset,
      declarationLine: declLine,
      firstMutationLine: mutations[element]!.firstMutationLine,
    );
  }

  int _resolveOffset(Element element) => element.firstFragment.nameOffset ?? -1;

  String _resolveTypeName(VariableElement element) {
    final type = element.type.getDisplayString();
    return type.isNotEmpty ? type : 'dynamic';
  }
}
