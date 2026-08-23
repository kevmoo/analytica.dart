import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:path/path.dart' as p;

const _declarationHeaderKeywords = {
  'abstract',
  'augment',
  'base',
  'extension',
  'external',
  'final',
  'interface',
  'late',
  'macro',
  'mixin',
  'sealed',
  'type',
};

/// Extracts a string name from an AST node safely.
///
/// Supports [ClassDeclaration], [FunctionDeclaration], [EnumDeclaration],
/// [MixinDeclaration], [ExtensionDeclaration], [ExtensionTypeDeclaration],
/// [TypeAlias], [VariableDeclaration], [MethodDeclaration],
/// and [ConstructorDeclaration], falling back to recursive identifier token
/// scanning.
String? extractNodeName(AstNode node) => switch (node) {
  ClassDeclaration(:final declaredFragment, :final namePart) =>
    declaredFragment?.element.name ?? namePart.typeName.lexeme,
  ClassTypeAlias(:final declaredFragment, :final name) =>
    declaredFragment?.element.name ?? name.lexeme,
  EnumDeclaration(:final declaredFragment, :final namePart) =>
    declaredFragment?.element.name ?? namePart.typeName.lexeme,
  MixinDeclaration(:final declaredFragment, :final name) =>
    declaredFragment?.element.name ?? name.lexeme,
  ExtensionDeclaration(:final declaredFragment, :final name) =>
    declaredFragment?.element.name ?? name?.lexeme,
  ExtensionTypeDeclaration(:final declaredFragment, :final namePart) =>
    declaredFragment?.element.name ?? namePart.typeName.lexeme,
  TypeAlias(:final declaredFragment, :final name) =>
    declaredFragment?.element.name ?? name.lexeme,
  FunctionDeclaration(:final declaredFragment, :final name) =>
    declaredFragment?.element.name ?? name.lexeme,
  VariableDeclaration(:final declaredFragment, :final name) =>
    declaredFragment?.element.name ?? name.lexeme,
  MethodDeclaration(:final declaredFragment, :final name) =>
    declaredFragment?.element.name ?? name.lexeme,
  ConstructorDeclaration(:final declaredFragment, :final name) =>
    declaredFragment?.element.name ?? name?.lexeme,
  EnumConstantDeclaration(:final name) => name.lexeme,
  TopLevelVariableDeclaration(:final variables)
      when variables.variables.isNotEmpty =>
    extractNodeName(variables.variables.first),
  FieldDeclaration(:final fields) when fields.variables.isNotEmpty =>
    extractNodeName(fields.variables.first),
  _ => _findFirstIdentifier(node),
};

String? _findFirstIdentifier(AstNode node) {
  for (final entity in node.childEntities) {
    if (entity is NodeList<Annotation> ||
        entity is Annotation ||
        entity is Comment ||
        entity is CommentReference) {
      continue;
    }
    if (entity is Token &&
        entity.type == TokenType.IDENTIFIER &&
        !_declarationHeaderKeywords.contains(entity.lexeme)) {
      return entity.lexeme;
    }
    if (entity is AstNode) {
      final nested = _findFirstIdentifier(entity);
      if (nested != null) return nested;
    }
  }
  return null;
}

/// Finds the enclosing top-level element for a given element by climbing
/// the enclosing hierarchy until reaching the library element or null.
Element? getTopLevelElement(Element elem) {
  if (elem is LibraryElement) return null;
  Element? current = elem;
  while (current != null) {
    final enclosing = current.enclosingElement;
    if (enclosing == null || enclosing is LibraryElement) {
      return current;
    }
    current = enclosing;
  }
  return null;
}

/// Checks if an [AnnotatedNode] contains an annotation with the given
/// [annotationName] (e.g. `'visibleForTesting'`, `'pragma'`, `'Native'`).
///
/// Matches both simple names (e.g. `@visibleForTesting`), prefixed names
/// (e.g. `@meta.visibleForTesting`), and constructor invocations
/// (e.g. `@Meta.visibleForTesting()`).
bool hasAnnotation(AnnotatedNode node, String annotationName) {
  for (final meta in node.metadata) {
    final rawName = meta.name.name;
    final baseName = rawName.contains('.') ? rawName.split('.').last : rawName;
    if (baseName == annotationName) {
      return true;
    }
    final constructorName = meta.constructorName?.name;
    if (constructorName == annotationName) {
      return true;
    }
  }
  return false;
}

/// Checks if an [AnnotatedNode] has any of the given [annotationNames].
bool hasAnyAnnotation(AnnotatedNode node, Iterable<String> annotationNames) {
  final nameSet = annotationNames.toSet();
  for (final meta in node.metadata) {
    final rawName = meta.name.name;
    final baseName = rawName.contains('.') ? rawName.split('.').last : rawName;
    if (nameSet.contains(baseName)) {
      return true;
    }
    final constructorName = meta.constructorName?.name;
    if (constructorName != null && nameSet.contains(constructorName)) {
      return true;
    }
  }
  return false;
}

/// Checks if an element or AST node has test support annotations or
/// conventions.
///
/// Checks for `@visibleForTesting`, `@visibleForOverriding`, `@protected`,
/// or if [name] starts/ends with `Fake` or `Mock`.
bool isTestSupportDeclaration(AnnotatedNode node, [String? name]) {
  final effectiveName = name ?? extractNodeName(node);
  if (effectiveName != null) {
    if (effectiveName.startsWith('Fake') ||
        effectiveName.startsWith('Mock') ||
        effectiveName.endsWith('Fake') ||
        effectiveName.endsWith('Mock')) {
      return true;
    }
  }

  return hasAnyAnnotation(node, const [
    'visibleForTesting',
    'VisibleForTesting',
    'visibleForOverriding',
    'VisibleForOverriding',
    'protected',
    'Protected',
  ]);
}

const _nativeAnnotationNames = {'Native', 'native'};
const _entryPointPragmas = {
  'vm:entry-point',
  'vm:entrypoint',
  'vm:isolate-unsendable',
  'wasm:entry-point',
  'wasm:export',
  'dyn-module:entry-point',
};

/// Checks if an AST node has native or runtime entrypoint annotations
/// (`@Native`, `@native`, or explicit entrypoint `@pragma` like
/// `@pragma('vm:entry-point')` or `@pragma('vm:isolate-unsendable')`).
///
/// Optimization and inlining pragmas (e.g. `@pragma('vm:prefer-inline')`,
/// `@pragma('dart2js:noInline')`) are NOT treated as entrypoints.
bool isNativeOrEntryPoint(AnnotatedNode node) {
  for (final meta in node.metadata) {
    final rawName = meta.name.name;
    final baseName = rawName.contains('.') ? rawName.split('.').last : rawName;
    if (_nativeAnnotationNames.contains(baseName)) {
      return true;
    }
    final constructorName = meta.constructorName?.name;
    if (constructorName != null &&
        _nativeAnnotationNames.contains(constructorName)) {
      return true;
    }
    if (baseName == 'pragma' || constructorName == 'pragma') {
      final args = meta.arguments?.arguments;
      if (args != null && args.isNotEmpty) {
        final firstArg = args.first;
        String? pragmaName;
        if (firstArg is SimpleStringLiteral) {
          pragmaName = firstArg.value;
        } else if (firstArg is StringLiteral) {
          pragmaName = firstArg.stringValue;
        } else {
          for (final entity in firstArg.childEntities) {
            if (entity is SimpleStringLiteral) {
              pragmaName = entity.value;
              break;
            } else if (entity is StringLiteral) {
              pragmaName = entity.stringValue;
              break;
            }
          }
        }
        if (pragmaName != null && _entryPointPragmas.contains(pragmaName)) {
          return true;
        }
      }
    }
  }
  return false;
}

/// Whether [relativePath] sits inside a directory that should never be
/// scanned (`.dart_tool`, `.git`, or `build` output).
///
/// Matches whole path segments, so `.github/` or `builders/` are not
/// mistaken for `.git/` or `build/`.
bool isExcludedPath(String relativePath) {
  final segments = p.split(p.normalize(relativePath));
  if (segments.isEmpty) return false;
  return segments.contains('.dart_tool') ||
      segments.contains('.git') ||
      segments.first == 'build';
}
