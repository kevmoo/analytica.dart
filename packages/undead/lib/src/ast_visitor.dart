import 'package:analytica/analyzer.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:path/path.dart' as p;

export 'package:analytica/analyzer.dart'
    show
        extractNodeName,
        getTopLevelElement,
        isNativeOrEntryPoint,
        isTestSupportDeclaration;

/// AST Visitor that gathers all references to top-level elements within a
/// declaration or code block, strictly ignoring doc comments and comments.
class ElementReferenceExtractor extends RecursiveAstVisitor<void> {
  final String packageRoot;
  final String _canonicalPackageRoot;
  final Set<Element> referencedTopLevelElements = {};

  ElementReferenceExtractor(this.packageRoot)
    : _canonicalPackageRoot = p.canonicalize(packageRoot);

  @override
  void visitComment(Comment node) {
    // Intentionally skipped: References in doc comments (e.g. `/// [Foo]`)
    // do not count as code reachability edges per PRD Stage 2 (E3).
  }

  void _checkElement(Element? elem) {
    if (elem == null) return;
    if (elem is MultiplyDefinedElement) {
      for (final conflicting in elem.conflictingElements) {
        _checkElement(conflicting);
      }
      return;
    }

    // Check if element belongs to target package.
    final sourcePath =
        elem.library?.firstFragment.source.fullName ??
        elem.firstFragment.libraryFragment?.source.fullName;
    if (sourcePath != null) {
      final normalizedSource = p.normalize(sourcePath);
      final canonicalSource = p.canonicalize(sourcePath);
      if (p.isWithin(packageRoot, normalizedSource) ||
          p.isWithin(_canonicalPackageRoot, canonicalSource)) {
        final topLevel = getTopLevelElement(elem);
        if (topLevel != null) {
          referencedTopLevelElements.add(topLevel);
        }
      }
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
      final definedNames = exportedLibrary.exportNamespace.definedNames2;
      var availableNames = Map<String, Element?>.from(definedNames);

      for (final combinator in node.combinators) {
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

      for (final elem in availableNames.values) {
        _checkElement(elem);
      }
    }

    for (final meta in node.metadata) {
      meta.accept(this);
    }
  }
}
