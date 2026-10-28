import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';

import '../analyzer/ast_helpers.dart';
import 'models.dart';

/// Utilities for mapping modified line ranges from git diffs to AST
/// declarations.
// ignore: avoid_classes_with_only_static_members, public API
class AstLineMapper {
  /// Maps [ranges] to enclosing declarations in [unit].
  ///
  /// If [includeMembers] is `true` (default), class/mixin/extension members
  /// (methods, constructors, fields) are also mapped individually alongside
  /// their enclosing parent declaration.
  static List<MappedDeclaration> mapDeclarations(
    CompilationUnit unit,
    LineInfo lineInfo,
    List<LineRange> ranges, {
    bool includeMembers = true,
  }) {
    if (ranges.isEmpty) return const [];

    final visitor = _DeclarationLineVisitor(
      lineInfo: lineInfo,
      ranges: ranges,
      includeMembers: includeMembers,
    );
    unit.accept(visitor);
    return visitor.results;
  }

  /// Maps the added/modified line ranges of [fileDiff] to enclosing
  /// declarations in [unit].
  static List<MappedDeclaration> mapDiffToDeclarations(
    CompilationUnit unit,
    LineInfo lineInfo,
    GitFileDiff fileDiff, {
    bool includeMembers = true,
  }) => mapDeclarations(
    unit,
    lineInfo,
    fileDiff.addedOrModifiedLineRanges,
    includeMembers: includeMembers,
  );

  /// Filters mapped declarations to executable subroutines
  /// ([FunctionDeclaration], [MethodDeclaration], [ConstructorDeclaration]).
  static List<MappedDeclaration> findFunctionsAndMethods(
    CompilationUnit unit,
    LineInfo lineInfo,
    List<LineRange> ranges,
  ) {
    final all = mapDeclarations(unit, lineInfo, ranges);
    return all
        .where(
          (m) =>
              m.node is FunctionDeclaration ||
              m.node is MethodDeclaration ||
              m.node is ConstructorDeclaration,
        )
        .toList();
  }

  /// Filters mapped declarations to top-level types
  /// ([ClassDeclaration], [EnumDeclaration], [MixinDeclaration],
  /// [ExtensionDeclaration], [ExtensionTypeDeclaration], [TypeAlias]).
  static List<MappedDeclaration> findTypes(
    CompilationUnit unit,
    LineInfo lineInfo,
    List<LineRange> ranges,
  ) {
    final all = mapDeclarations(unit, lineInfo, ranges, includeMembers: false);
    return all
        .where(
          (m) =>
              m.node is ClassDeclaration ||
              m.node is EnumDeclaration ||
              m.node is MixinDeclaration ||
              m.node is ExtensionDeclaration ||
              m.node is ExtensionTypeDeclaration ||
              m.node is TypeAlias,
        )
        .toList();
  }
}

class _DeclarationLineVisitor extends RecursiveAstVisitor<void> {
  final LineInfo lineInfo;
  final List<LineRange> ranges;
  final bool includeMembers;
  final List<MappedDeclaration> results = [];

  _DeclarationLineVisitor({
    required this.lineInfo,
    required this.ranges,
    required this.includeMembers,
  });

  void _checkDeclaration(AstNode node, String? explicitName) {
    final startLoc = lineInfo.getLocation(node.offset);
    final endLoc = lineInfo.getLocation(node.end);
    final startLine = startLoc.lineNumber;
    final endLine = endLoc.lineNumber;

    final intersecting = ranges
        .where((r) => r.intersects(startLine, endLine))
        .toList();

    if (intersecting.isNotEmpty) {
      final name = explicitName ?? extractNodeName(node) ?? '<anonymous>';
      results.add(
        MappedDeclaration(
          node: node,
          name: name,
          startLine: startLine,
          endLine: endLine,
          intersectingRanges: intersecting,
        ),
      );
    }
  }

  String? _getEnclosingName(AstNode node) {
    var current = node.parent;
    while (current != null) {
      if (current is ClassDeclaration ||
          current is EnumDeclaration ||
          current is MixinDeclaration ||
          current is ExtensionDeclaration ||
          current is ExtensionTypeDeclaration) {
        return extractNodeName(current);
      }
      current = current.parent;
    }
    return null;
  }

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    _checkDeclaration(node, extractNodeName(node));
    if (includeMembers) {
      super.visitClassDeclaration(node);
    }
  }

  @override
  void visitEnumDeclaration(EnumDeclaration node) {
    _checkDeclaration(node, extractNodeName(node));
    if (includeMembers) {
      super.visitEnumDeclaration(node);
    }
  }

  @override
  void visitMixinDeclaration(MixinDeclaration node) {
    _checkDeclaration(node, extractNodeName(node));
    if (includeMembers) {
      super.visitMixinDeclaration(node);
    }
  }

  @override
  void visitExtensionDeclaration(ExtensionDeclaration node) {
    _checkDeclaration(node, extractNodeName(node));
    if (includeMembers) {
      super.visitExtensionDeclaration(node);
    }
  }

  @override
  void visitExtensionTypeDeclaration(ExtensionTypeDeclaration node) {
    _checkDeclaration(node, extractNodeName(node));
    if (includeMembers) {
      super.visitExtensionTypeDeclaration(node);
    }
  }

  @override
  void visitGenericTypeAlias(GenericTypeAlias node) {
    _checkDeclaration(node, extractNodeName(node));
  }

  @override
  void visitFunctionTypeAlias(FunctionTypeAlias node) {
    _checkDeclaration(node, extractNodeName(node));
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    if (node.parent is CompilationUnit) {
      _checkDeclaration(node, extractNodeName(node));
    }
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    if (!includeMembers) return;
    final rawName = node.name.lexeme;
    final enclosing = _getEnclosingName(node);
    final fullName = enclosing != null ? '$enclosing.$rawName' : rawName;
    _checkDeclaration(node, fullName);
  }

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    if (!includeMembers) return;
    final enclosing = _getEnclosingName(node) ?? 'Constructor';
    final constName = node.name?.lexeme;
    final fullName = constName != null ? '$enclosing.$constName' : enclosing;
    _checkDeclaration(node, fullName);
  }

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    if (node.parent is VariableDeclarationList &&
        node.parent?.parent is CompilationUnit) {
      _checkDeclaration(node, node.name.lexeme);
    }
    super.visitVariableDeclaration(node);
  }

  @override
  void visitFieldDeclaration(FieldDeclaration node) {
    if (!includeMembers) return;
    final enclosing = _getEnclosingName(node);
    for (final field in node.fields.variables) {
      final rawName = field.name.lexeme;
      final fullName = enclosing != null ? '$enclosing.$rawName' : rawName;
      _checkDeclaration(field, fullName);
    }
  }
}
