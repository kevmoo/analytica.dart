import '../models.dart';

/// Formatter that outputs [DedupeReport] as concise terminal text.
class TextFormatter {
  final int topCount;
  final String categoryFilter;
  final String bucketFilter;

  const TextFormatter({
    this.topCount = 0,
    this.categoryFilter = 'all',
    this.bucketFilter = 'all',
  });

  String format(DedupeReport report) {
    final buffer = StringBuffer();
    final summary = report.summary;

    buffer.writeln('Dedupe Duplication Summary: ${report.targetPath}');
    buffer.writeln('-' * 60);
    buffer.writeln('  Files Analyzed:          ${summary.filesAnalyzed}');
    buffer.writeln('  Total Lines:             ${summary.totalLines}');
    buffer.writeln(
      '  Duplicate Lines:         ${summary.duplicateLines} '
      '(${summary.duplicationPercentage.toStringAsFixed(1)}%)',
    );
    buffer.writeln('  Duplicate Clusters:      ${summary.clusterCount}');
    buffer.writeln('  Clone Instances:         ${summary.cloneInstanceCount}');
    buffer.writeln('  Estimated Lines Saved:   ${summary.estimatedLinesSaved}');

    if (summary.diffDuplicationPercentage != null) {
      buffer.writeln(
        '  Diff Duplication:        '
        '${summary.diffDuplicationPercentage!.toStringAsFixed(1)}%',
      );
      if (summary.clustersOutsideDiff > 0) {
        buffer.writeln(
          '  Clusters Outside Diff:   ${summary.clustersOutsideDiff}',
        );
      }
    }
    buffer.writeln('-' * 60);

    var clusters = report.clusters;
    if (categoryFilter != 'all') {
      clusters = clusters
          .where((c) => c.category.jsonValue == categoryFilter)
          .toList();
    }
    if (bucketFilter != 'all') {
      clusters = clusters
          .where((c) => c.bucket.jsonValue == bucketFilter)
          .toList();
    }
    if (topCount > 0 && clusters.length > topCount) {
      clusters = clusters.sublist(0, topCount);
    }

    if (clusters.isNotEmpty) {
      buffer.writeln('\nTop Duplicate Clusters:');
      for (final cluster in clusters) {
        final diffBadge = cluster.intersectsDiff ? ' [IN DIFF]' : '';
        buffer.writeln(
          '  [${cluster.id}] ${cluster.category.displayName} '
          '(${cluster.bucket.displayName}) - '
          '~${cluster.estimatedLinesSaved} lines saved across '
          '${cluster.instances.length} occurrences$diffBadge',
        );
        for (final instance in cluster.instances) {
          final inDiffTag = instance.inDiff ? ' [in diff]' : '';
          final loc =
              '${instance.filePath}:${instance.startLine}-${instance.endLine}';
          final stats =
              '(${instance.lineCount} lines, ${instance.tokenCount} tokens)';
          buffer.writeln('    - $loc $stats$inDiffTag');
        }
      }
    }

    return buffer.toString().trimRight();
  }
}
