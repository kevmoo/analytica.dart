import 'package:dedupe/dedupe.dart';

void main() async {
  final options = DedupeOptions(
    targetPath: '.',
    minTokens: 30,
    minLines: 4,
    format: OutputFormat.markdown,
  );

  final engine = DedupeEngine(options);
  final report = await engine.analyze();

  final summary = report.summary;
  print(
    'Duplicate lines: ${summary.duplicateLines} '
    '(${summary.duplicationPercentage.toStringAsFixed(1)}%)',
  );
  print('Clusters found: ${report.clusters.length}');

  for (final cluster in report.clusters) {
    print(
      'Cluster ${cluster.id}: ~${cluster.estimatedLinesSaved} lines saved '
      'across ${cluster.instances.length} locations',
    );
  }
}
