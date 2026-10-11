import 'package:analytica/analyzer.dart';
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
    if (hasAnyAnnotation(node, _jsInteropAnnotations)) return true;

    if (node is! ExtensionTypeDeclaration) {
      return switch (node) {
        FunctionDeclaration(:final externalKeyword) ||
        TopLevelVariableDeclaration(
          :final externalKeyword,
        ) => externalKeyword != null,
        ClassDeclaration() ||
        ExtensionDeclaration() ||
        MixinDeclaration() ||
        EnumDeclaration() => _hasExternalMember(node),
        _ => false,
      };
    }

    if (_hasExternalMember(node)) return true;
    for (final child in node.childEntities) {
      if (child is! AstNode) continue;
      final kind = child.runtimeType.toString();
      final isRep =
          child is FormalParameterList ||
          kind.contains('Representation') ||
          kind.contains('PrimaryConstructor');
      if (isRep && _hasJsRepresentationType(child.toSource())) {
        return true;
      }
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
