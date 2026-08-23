import 'package:dedupe/dedupe.dart';

void main() async {
  // Configure analysis options.
  final options = DedupeOptions(
    targetPath: '.',
    minTokens: 30,
    minLines: 4,
    ignoreComments: true,
    ignoreLiterals: true,
    ignoreIdentifiers: false,
  );

  // Initialize the deduplication engine and run the analysis.
  final engine = DedupeEngine(options);
  final report = await engine.analyze();

  // Inspect aggregate summary metrics.
  final summary = report.summary;
  print('Deduplication Analysis Summary:');
  print('  Files analyzed: ${summary.filesAnalyzed}');
  print('  Total lines: ${summary.totalLines}');
  print('  Duplicate lines: ${summary.duplicateLines}');
  print(
    '  Duplication rate: '
    '${summary.duplicationPercentage.toStringAsFixed(1)}%',
  );
  print('  Duplicate clusters found: ${summary.clusterCount}');
  print('  Estimated lines saved: ${summary.estimatedLinesSaved}');

  // Inspect individual duplicate clusters.
  if (report.clusters.isNotEmpty) {
    print('\nDetected Duplicate Clusters:');
    for (final cluster in report.clusters) {
      print(
        '  [Cluster ${cluster.id}] '
        '${cluster.category.displayName} (${cluster.bucket.displayName}):',
      );
      print(
        '    Instances: ${cluster.instanceCount}, '
        'Lines: ${cluster.lineCount}, '
        'Tokens: ${cluster.tokenCount}',
      );
      for (final instance in cluster.instances) {
        print(
          '      - ${instance.filePath}:'
          '${instance.startLine}-${instance.endLine}',
        );
      }
    }
  } else {
    print('\nNo duplicate code clusters detected.');
  }
}
