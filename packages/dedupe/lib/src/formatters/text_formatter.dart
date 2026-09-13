import '../models.dart';
import 'cluster_filter.dart';

/// Formatter that outputs [DedupeReport] as concise terminal text.
class TextFormatter with ClusterFilterMixin {
  @override
  final int topCount;
  @override
  final String categoryFilter;
  @override
  final String bucketFilter;

  const TextFormatter({
    this.topCount = 0,
    this.categoryFilter = 'all',
    this.bucketFilter = 'all',
  });

  String format(DedupeReport report) {
    final buffer = StringBuffer();
    _writeSummary(buffer, report);

    final clusters = filterClusters(report.clusters);
    if (clusters.isNotEmpty) {
      _writeClusters(buffer, clusters);
    }

    return buffer.toString().trimRight();
  }

  static void _writeSummary(StringBuffer buffer, DedupeReport report) {
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
  }


  static void _writeClusters(
    StringBuffer buffer,
    List<DuplicateCluster> clusters,
  ) {
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
}
