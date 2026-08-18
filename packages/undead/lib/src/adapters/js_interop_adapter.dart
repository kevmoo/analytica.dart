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

  static const _jsInteropTypeNames = {
    'JSAny',
    'JSObject',
    'JSFunction',
    'JSArray',
    'JSString',
    'JSNumber',
    'JSBoolean',
    'JSPromise',
    'JSSymbol',
    'JSBigInt',
    'JSBoxedDartObject',
    'JSTypedArray',
    'JSUint8Array',
    'JSInt8Array',
    'JSUint8ClampedArray',
    'JSInt16Array',
    'JSUint16Array',
    'JSInt32Array',
    'JSUint32Array',
    'JSFloat32Array',
    'JSFloat64Array',
    'JSArrayBuffer',
    'JSDataView',
    'JSExportedDartFunction',
  };

  @override
  bool isFrameworkEntryPoint(AnnotatedNode node, Element? element) {
    for (final meta in node.metadata) {
      final pragmaName = extractPragmaName(meta);
      if (pragmaName != null &&
          _wasmEntryPointPragmas.any(
            (p) => pragmaName == p || pragmaName.startsWith('$p:'),
          )) {
        return true;
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

    // 3. ExtensionTypeDeclaration: Check direct representation or external
    // members.
    if (node is ExtensionTypeDeclaration) {
      if (_hasExternalMember(node)) return true;
      for (final child in node.childEntities) {
        if (child is FormalParameterList) {
          final src = child.toSource();
          if (_hasJsRepresentationType(src)) return true;
        } else if (child is AstNode &&
            (child.runtimeType.toString().contains('Representation') ||
                child.runtimeType.toString().contains('PrimaryConstructor'))) {
          final src = child.toSource();
          if (_hasJsRepresentationType(src)) return true;
        }
      }
    }

    // 4. ClassDeclaration, ExtensionDeclaration, MixinDeclaration,
    // EnumDeclaration: Check direct external members.
    if (node is ClassDeclaration ||
        node is ExtensionDeclaration ||
        node is MixinDeclaration ||
        node is EnumDeclaration) {
      if (_hasExternalMember(node)) return true;
    }

    return false;
  }

  static bool _hasJsRepresentationType(String src) {
    for (final typeName in _jsInteropTypeNames) {
      if (src.contains(typeName)) return true;
    }
    return false;
  }

  static bool _hasExternalMember(AstNode node) {
    for (final child in node.childEntities) {
      if (_isExternalMember(child)) return true;
      if (child is AstNode &&
          (child.runtimeType.toString().contains('Body') ||
              child.runtimeType.toString().contains('Clause'))) {
        for (final member in child.childEntities) {
          if (_isExternalMember(member)) return true;
        }
      }
    }
    return false;
  }

  static bool _isExternalMember(dynamic member) {
    if (member is MethodDeclaration && member.externalKeyword != null) {
      return true;
    }
    if (member is FieldDeclaration && member.externalKeyword != null) {
      return true;
    }
    if (member is ConstructorDeclaration && member.externalKeyword != null) {
      return true;
    }
    return false;
  }
}
