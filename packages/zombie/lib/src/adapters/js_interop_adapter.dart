import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';

import 'framework_adapter.dart';

/// Adapter for JavaScript and WebAssembly interop conventions, entrypoint
/// pragmas, and `external` facade declarations.
class JsInteropAdapter extends BaseFrameworkAdapter {
  const JsInteropAdapter();

  static const _wasmEntryPointPragmas = {
    'wasm:export',
    'wasm:entry-point',
    'wasm:entrypoint',
  };

  static const _jsInteropAnnotations = {'JS', 'staticInterop', 'anonymous'};

  @override
  bool isFrameworkEntryPoint(AnnotatedNode node, Element? element) {
    for (final meta in node.metadata) {
      final rawName = meta.name.name;
      final baseName = rawName.contains('.')
          ? rawName.split('.').last
          : rawName;
      final constructorName = meta.constructorName?.name;

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
          final name = pragmaName;
          if (name != null &&
              _wasmEntryPointPragmas.any(
                (p) => name == p || name.startsWith('$p:'),
              )) {
            return true;
          }
        }
      }
    }
    return false;
  }

  @override
  bool isExternalBinding(Declaration node, Element? element) {
    // 1. Check for external keyword on top-level function or variable.
    if (node is FunctionDeclaration && node.externalKeyword != null) {
      return true;
    }
    if (node is TopLevelVariableDeclaration && node.externalKeyword != null) {
      return true;
    }

    // 2. Check for @JS, @staticInterop, @anonymous annotations.
    for (final meta in node.metadata) {
      final rawName = meta.name.name;
      final baseName = rawName.contains('.')
          ? rawName.split('.').last
          : rawName;
      final constructorName = meta.constructorName?.name;
      if (_jsInteropAnnotations.contains(baseName) ||
          _jsInteropAnnotations.contains(constructorName)) {
        return true;
      }
    }

    // 3. Check for ExtensionTypeDeclaration or ClassDeclaration representing JS interop / having external members.
    if (node is ExtensionTypeDeclaration || node is ClassDeclaration) {
      var hasExternalMember = false;
      var hasJsRepresentation = false;

      void inspectEntities(Iterable<dynamic> entities) {
        for (final entity in entities) {
          if (entity is MethodDeclaration && entity.externalKeyword != null) {
            hasExternalMember = true;
          } else if (entity is FieldDeclaration &&
              entity.externalKeyword != null) {
            hasExternalMember = true;
          } else if (entity is ConstructorDeclaration &&
              entity.externalKeyword != null) {
            hasExternalMember = true;
          } else if (entity is FormalParameterList) {
            final src = entity.toSource();
            if (src.contains('JSObject') ||
                src.contains('JSAny') ||
                src.contains('JSString') ||
                src.contains('JSNumber') ||
                src.contains('JSBoolean') ||
                src.contains('JSArray') ||
                src.contains('JSPromise')) {
              hasJsRepresentation = true;
            }
          } else if (entity is AstNode) {
            inspectEntities(entity.childEntities);
          }
        }
      }

      inspectEntities(node.childEntities);
      if (hasJsRepresentation || hasExternalMember) {
        return true;
      }
    }

    return false;
  }
}
