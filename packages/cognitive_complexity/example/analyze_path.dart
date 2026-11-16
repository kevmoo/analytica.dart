import 'package:cognitive_complexity/cognitive_complexity.dart';

void main() {
  final analyzer = ComplexityAnalyzer();
  final results = analyzer.analyzePath('lib');

  for (final res in results) {
    print(
      '${res.name}: score is ${res.score} (${res.filePath}:L${res.startLine})',
    );
  }
}
