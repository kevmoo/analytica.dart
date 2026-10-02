import 'models.dart';

/// Synthesizes idiomatic Dart method signatures with Dart 3 Records.
class SignatureSynthesizer {
  const SignatureSynthesizer();

  /// Generates a proposed function signature from analyzed inputs and outputs.
  String synthesize({
    required List<VariableUsage> inputs,
    required List<VariableUsage> outputs,
    List<String> typeParameters = const [],
    String methodName = '_extracted',
    bool isAsync = false,
  }) {
    final returnType = _buildReturnType(outputs, isAsync: isAsync);
    final params = inputs.isEmpty
        ? ''
        : inputs.map((i) => '${i.type} ${i.name}').join(', ');
    final asyncSuffix = isAsync ? ' async' : '';
    final typeParamsStr = typeParameters.isNotEmpty
        ? '<${typeParameters.join(', ')}>'
        : '';

    return '$returnType $methodName$typeParamsStr($params)$asyncSuffix';
  }

  String _uniqueFieldName(String name, Set<String> usedNames) {
    var base = name.replaceFirst(RegExp(r'^_+'), '');
    if (base.isEmpty) base = 'result';
    if (usedNames.add(base)) return base;
    var suffix = 2;
    while (!usedNames.add('$base$suffix')) {
      suffix++;
    }
    return '$base$suffix';
  }

  String _buildReturnType(
    List<VariableUsage> outputs, {
    required bool isAsync,
  }) {
    String baseType;
    if (outputs.isEmpty) {
      baseType = 'void';
    } else if (outputs.length == 1) {
      baseType = outputs.first.type;
    } else {
      final usedNames = <String>{};
      final fields = outputs
          .map((o) => '${o.type} ${_uniqueFieldName(o.name, usedNames)}')
          .join(', ');
      baseType = '({$fields})';
    }

    if (isAsync) {
      if (baseType == 'void') {
        return 'Future<void>';
      }
      return 'Future<$baseType>';
    }

    return baseType;
  }
}
