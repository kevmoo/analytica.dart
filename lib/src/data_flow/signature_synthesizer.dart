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
    final params = _buildParameters(inputs);
    final asyncSuffix = isAsync ? ' async' : '';
    final typeParamsStr = _buildTypeParamsStr(typeParameters);

    return '$returnType $methodName$typeParamsStr($params)$asyncSuffix';
  }

  String _buildTypeParamsStr(List<String> typeParameters) {
    return typeParameters.isNotEmpty ? '<${typeParameters.join(', ')}>' : '';
  }

  String _sanitizeRecordFieldName(String name) {
    var sanitized = name.replaceFirst(RegExp(r'^_+'), '');
    if (sanitized.isEmpty) sanitized = 'result';
    return sanitized;
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
          .map((o) {
            var cleanName = _sanitizeRecordFieldName(o.name);
            if (!usedNames.add(cleanName)) {
              var suffix = 2;
              while (!usedNames.add('$cleanName$suffix')) {
                suffix++;
              }
              cleanName = '$cleanName$suffix';
            }
            return '${o.type} $cleanName';
          })
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

  String _buildParameters(List<VariableUsage> inputs) {
    if (inputs.isEmpty) return '';
    return inputs.map((i) => '${i.type} ${i.name}').join(', ');
  }
}
