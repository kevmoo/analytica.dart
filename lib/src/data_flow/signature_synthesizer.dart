import 'models.dart';

/// Synthesizes idiomatic Dart method signatures with Dart 3 Records.
class SignatureSynthesizer {
  const SignatureSynthesizer();

  /// Generates a proposed function signature from analyzed inputs and outputs.
  String synthesize({
    required List<VariableUsage> inputs,
    required List<VariableUsage> outputs,
    String methodName = '_extracted',
    bool isAsync = false,
  }) {
    final returnType = _buildReturnType(outputs, isAsync: isAsync);
    final params = _buildParameters(inputs);
    final asyncSuffix = isAsync ? ' async' : '';

    return '$returnType $methodName($params)$asyncSuffix';
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
      final fields = outputs.map((o) => '${o.type} ${o.name}').join(', ');
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
