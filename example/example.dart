import 'package:cognitive_complexity/cognitive_complexity.dart';
import 'package:cognitive_complexity/data_flow.dart';

void main() async {
  // 1. Calculate Cognitive Complexity for Dart code.
  final complexityAnalyzer = ComplexityAnalyzer();
  const sampleCode = '''
void processItems(List<String> items, bool isStrict) {
  for (final item in items) {
    if (item.isNotEmpty) {
      if (isStrict) {
        print(item.toUpperCase());
      }
    }
  }
}
''';

  final complexities = complexityAnalyzer.analyzeCode(sampleCode);
  for (final fc in complexities) {
    print('${fc.name}: cognitive complexity = ${fc.score}');
  }

  // 2. Perform statement-level Data-Flow analysis on a code snippet.
  const dataFlowAnalyzer = DataFlowAnalyzer();
  const functionBody = '''
void processUser(String rawInput, int defaultAge) {
  final name = rawInput.trim();
  var age = defaultAge;
  if (name.isEmpty) {
    age = 0;
  }
  print('User: \$name, Age: \$age');
}
''';

  final dataFlowResult = await dataFlowAnalyzer.analyzeSource(
    sourceCode: functionBody,
    startLine: 3,
    endLine: 6,
    methodName: '_resolveUser',
  );

  print('Extractable: ${dataFlowResult.isCleanlyExtractable}');
  print('Inputs: ${dataFlowResult.inputs.map((u) => u.name).join(', ')}');
  print('Outputs: ${dataFlowResult.outputs.map((u) => u.name).join(', ')}');
  print('Suggested Signature: ${dataFlowResult.suggestedSignature}');
}
