import 'package:cognitive_complexity/data_flow.dart';

void main() async {
  const analyzer = DataFlowAnalyzer();
  final result = await analyzer.analyzeFile(
    filePath: 'lib/src/service.dart',
    startLine: 45,
    endLine: 80,
    methodName: '_processUser',
  );

  print('Cleanly extractable: ${result.isCleanlyExtractable}');
  print('Inputs: ${result.inputs.map((u) => u.name).join(', ')}');
  print('Outputs: ${result.outputs.map((u) => u.name).join(', ')}');
  print('Proposed Signature: ${result.suggestedSignature}');
}
