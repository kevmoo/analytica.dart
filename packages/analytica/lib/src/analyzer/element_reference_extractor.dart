import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:path/path.dart' as p;

import 'ast_helpers.dart';

/// AST Visitor that gathers all references to top-level elements, private
/// member accesses, and external library URIs within a declaration or code
/// block, strictly ignoring doc comments and comments.
class ElementReferenceExtractor extends RecursiveAstVisitor<void> {
  final String? packageRoot;
  final String? _canonicalPackageRoot;

  /// Top-level elements referenced by the visited AST subtree.
  final Set<Element> referencedTopLevelElements = {};

  /// Private member names (`_field`, `_method`, `_ctor`) accessed on each
  /// target top-level element (`targetTopLevelElement -> {'_foo', '_bar'}`).
  final Map<Element, Set<String>> privateMemberAccessesByTarget = {};

  /// Library URIs (`package:...`, `dart:...`, `file:...`) of elements
  /// referenced by the visited AST subtree (excluding `dart:core`).
  final Set<String> referencedLibraryUris = {};

  ElementReferenceExtractor([this.packageRoot])
    : _canonicalPackageRoot = packageRoot == null
          ? null
          : p.canonicalize(packageRoot);

  @override
  void visitComment(Comment node) {
    // Intentionally skipped: References in doc comments (e.g. `/// [Foo]`)
    // do not count as code reachability or coupling edges.
  }

  void _checkElement(Element? elem) {
    if (elem == null) return;
    if (elem is MultiplyDefinedElement) {
      elem.conflictingElements.forEach(_checkElement);
      return;
    }

    _recordLibraryUri(elem.library);
    final sourcePath = _resolveElementSourcePath(elem);
    if (sourcePath == null || !_isPathInScope(sourcePath)) return;

    final topLevel = getTopLevelElement(elem);
    if (topLevel == null) return;
    referencedTopLevelElements.add(topLevel);
    _recordPrivateMemberAccess(elem, topLevel);
  }

  void _recordLibraryUri(LibraryElement? lib) {
    if (lib == null) return;
    final uriStr = lib.uri.toString();
    if (uriStr != 'dart:core') {
      referencedLibraryUris.add(uriStr);
    }
  }

  String? _resolveElementSourcePath(Element elem) =>
      elem.library?.firstFragment.source.fullName ??
      elem.firstFragment.libraryFragment?.source.fullName;

  bool _isPathInScope(String sourcePath) {
    final root = packageRoot;
    final canonicalRoot = _canonicalPackageRoot;
    if (root == null || canonicalRoot == null) return true;
    return p.isWithin(root, p.normalize(sourcePath)) ||
        p.isWithin(canonicalRoot, p.canonicalize(sourcePath));
  }

  void _recordPrivateMemberAccess(Element elem, Element topLevel) {
    if (elem == topLevel) return;
    final memberName = elem.name;
    if (memberName != null && memberName.startsWith('_')) {
      privateMemberAccessesByTarget
          .putIfAbsent(topLevel, () => <String>{})
          .add(memberName);
    }
  }

  @override
  void visitNamedType(NamedType node) {
    _checkElement(node.element);
    super.visitNamedType(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    // Avoid recording declaration names as reference usages.
    if (!node.inDeclarationContext()) {
      _checkElement(node.element);
    }
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitConstructorName(ConstructorName node) {
    _checkElement(node.element);
    super.visitConstructorName(node);
  }

  @override
  void visitExtensionOverride(ExtensionOverride node) {
    _checkElement(node.element);
    super.visitExtensionOverride(node);
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    _checkElement(node.element);
    _checkElement(node.readElement);
    _checkElement(node.writeElement);
    super.visitAssignmentExpression(node);
  }

  @override
  void visitBinaryExpression(BinaryExpression node) {
    _checkElement(node.element);
    super.visitBinaryExpression(node);
  }

  @override
  void visitPrefixExpression(PrefixExpression node) {
    _checkElement(node.element);
    _checkElement(node.readElement);
    _checkElement(node.writeElement);
    super.visitPrefixExpression(node);
  }

  @override
  void visitPostfixExpression(PostfixExpression node) {
    _checkElement(node.element);
    _checkElement(node.readElement);
    _checkElement(node.writeElement);
    super.visitPostfixExpression(node);
  }

  @override
  void visitIndexExpression(IndexExpression node) {
    _checkElement(node.element);
    super.visitIndexExpression(node);
  }

  @override
  void visitAnnotation(Annotation node) {
    _checkElement(node.element);
    super.visitAnnotation(node);
  }

  @override
  void visitSuperConstructorInvocation(SuperConstructorInvocation node) {
    _checkElement(node.element);
    super.visitSuperConstructorInvocation(node);
  }

  @override
  void visitRedirectingConstructorInvocation(
    RedirectingConstructorInvocation node,
  ) {
    _checkElement(node.element);
    super.visitRedirectingConstructorInvocation(node);
  }

  @override
  void visitRelationalPattern(RelationalPattern node) {
    _checkElement(node.element);
    super.visitRelationalPattern(node);
  }

  @override
  void visitImportDirective(ImportDirective node) {
    // Skip combinators (show/hide) so unused imported names in import
    // directives do not falsely count as usage references.
    for (final meta in node.metadata) {
      meta.accept(this);
    }
  }

  @override
  void visitExportDirective(ExportDirective node) {
    final exportedLibrary = node.libraryExport?.exportedLibrary;
    if (exportedLibrary != null) {
      final availableNames = Map<String, Element?>.from(
        exportedLibrary.exportNamespace.definedNames2,
      );
      node.combinators.forEach(
        (c) => _applyExportCombinator(c, availableNames),
      );
      availableNames.values.forEach(_checkElement);
    }

    for (final meta in node.metadata) {
      meta.accept(this);
    }
  }

  void _applyExportCombinator(
    Combinator combinator,
    Map<String, Element?> availableNames,
  ) {
    if (combinator is ShowCombinator) {
      final shown = combinator.shownNames.map((id) => id.name).toSet();
      availableNames.removeWhere((name, _) => !shown.contains(name));
      for (final id in combinator.shownNames) {
        if (!availableNames.containsKey(id.name) && id.element != null) {
          availableNames[id.name] = id.element;
        }
      }
    } else if (combinator is HideCombinator) {
      final hidden = combinator.hiddenNames.map((id) => id.name).toSet();
      availableNames.removeWhere((name, _) => hidden.contains(name));
    }
  }
}
