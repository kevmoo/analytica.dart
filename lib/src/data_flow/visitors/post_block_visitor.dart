// ignore_for_file: avoid_dynamic_calls

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

  /// Variables that are live after the block and must be returned.
  final Map<Element, VariableUsage> liveOutputs = {};

  PostBlockVisitor({
    required this.sliceStartOffset,
    required this.sliceEndOffset,
    required this.lineInfo,
    required this.internalDeclarations,
    required this.mutations,
  });

  bool _isAfterSlice(AstNode node) => node.offset > sliceEndOffset;

  Element? _resolveElement(SimpleIdentifier node) {
    try {
      final dynamic d = node;
      try {
        final dynamic elem = d.element;
        if (elem is Element) return elem;
      } catch (_) {}
      try {
        final dynamic elem = d.staticElement;
        if (elem is Element) return elem;
      } catch (_) {}
    } catch (_) {}
    return null;
  }

  int _resolveOffset(Element element) {
    try {
      final dynamic d = element;
      try {
        final dynamic fragment = d.firstFragment;
        if (fragment != null) {
          final dynamic offset = fragment.nameOffset;
          if (offset is int) return offset;
        }
      } catch (_) {}
      try {
        final dynamic offset = d.nameOffset;
        if (offset is int) return offset;
      } catch (_) {}
    } catch (_) {}
    return -1;
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (!_isAfterSlice(node)) {
      super.visitSimpleIdentifier(node);
      return;
    }

    final element = _resolveElement(node);
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
        final mutation = mutations[element]!;
        liveOutputs[element] = VariableUsage(
          name: element.name ?? node.name,
          type: typeName,
          isMutated: true,
          declarationOffset: declOffset,
          declarationLine: declLine,
          firstMutationLine: mutation.firstMutationLine,
        );
      }
    }
  }

  String _resolveTypeName(VariableElement element) {
    try {
      final dynamic type = element.type;
      final dynamic display = type.getDisplayString();
      if (display is String && display.isNotEmpty) return display;
    } catch (_) {
      try {
        final dynamic type = element.type;
        final dynamic display = type.getDisplayString(withNullability: true);
        if (display is String && display.isNotEmpty) return display;
      } catch (_) {
        // Fallback
      }
    }
    return 'dynamic';
  }
}
