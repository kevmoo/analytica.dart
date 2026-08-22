import '../models.dart';

/// Formatter that outputs [DedupeReport] as clean GitHub-Flavored Markdown.
class MarkdownFormatter {
  final int topCount;
  final String categoryFilter;
  final String bucketFilter;
  final bool includeFileTable;
  final bool includeClusters;

  const MarkdownFormatter({
    this.topCount = 0,
    this.categoryFilter = 'all',
    this.bucketFilter = 'all',
    this.includeFileTable = true,
    this.includeClusters = true,
  });

  String format(DedupeReport report) {
    final buffer = StringBuffer();
    final summary = report.summary;

    buffer.writeln(
      '# 🔍 Dedupe Duplication Analysis: `${report.targetPath}`\n',
    );

    // 1. Summary Block
    buffer.writeln('## 📊 Summary\n');
    buffer.writeln('<!-- mdformat off(prevent table wrapping) -->');
    buffer.writeln('| Metric | Value |');
    buffer.writeln('| :--- | :--- |');
    buffer.writeln('| **Files Analyzed** | `${summary.filesAnalyzed}` |');
    buffer.writeln('| **Total Lines** | `${summary.totalLines}` |');
    buffer.writeln(
      '| **Duplicate Lines** | `${summary.duplicateLines}` '
      '(${summary.duplicationPercentage.toStringAsFixed(1)}%) |',
    );
    buffer.writeln('| **Duplicate Clusters** | `${summary.clusterCount}` |');
    buffer.writeln('| **Clone Instances** | `${summary.cloneInstanceCount}` |');
    buffer.writeln(
      '| **Estimated Lines Saved** | `${summary.estimatedLinesSaved}` |',
    );

    if (summary.diffDuplicationPercentage != null) {
      buffer.writeln(
        '| **Diff Duplication** | '
        '${summary.diffDuplicationPercentage!.toStringAsFixed(1)}% |',
      );
      if (summary.clustersOutsideDiff > 0) {
        buffer.writeln(
          '| **Clusters Outside Diff** | `${summary.clustersOutsideDiff}` |',
        );
      }
    }
    buffer.writeln('<!-- mdformat on -->\n');

    // 2. Per-File Metrics Table
    if (includeFileTable && report.fileMetrics.isNotEmpty) {
      final duplicateFiles =
          report.fileMetrics.where((f) => f.duplicateLines > 0).toList()..sort(
            (a, b) =>
                b.duplicationPercentage.compareTo(a.duplicationPercentage),
          );

      if (duplicateFiles.isNotEmpty) {
        buffer.writeln('## 📁 File Breakdown\n');
        buffer.writeln('<!-- mdformat off(prevent table wrapping) -->');
        buffer.writeln(
          '| File | Total Lines | Duplicate Lines | Duplication % | Clusters |',
        );
        buffer.writeln('| :--- | :---: | :---: | :---: | :---: |');
        for (final file in duplicateFiles) {
          final dupPct = file.duplicationPercentage.toStringAsFixed(1);
          buffer.writeln(
            '| `${file.filePath}` | ${file.totalLines} | '
            '${file.duplicateLines} | $dupPct% | ${file.clusterCount} |',
          );
        }
        buffer.writeln('<!-- mdformat on -->\n');
      }
    }

    // 3. Filtered Clusters
    if (includeClusters) {
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

      if (clusters.isEmpty) {
        if (report.clusters.isEmpty) {
          buffer.writeln('## ✨ Zero Code Duplication Detected\n');
          buffer.writeln(
            'No structural code clones meeting threshold criteria were found '
            'in the scanned files.\n',
          );
        } else {
          buffer.writeln('## 🔍 Duplicate Clusters\n');
          buffer.writeln(
            'No duplicate clusters matched the current filter criteria.\n',
          );
        }
      } else {
        buffer.writeln('## 🔍 Duplicate Clusters\n');

        for (final cluster in clusters) {
          final diffBadge = cluster.intersectsDiff
              ? (cluster.isNewlyIntroduced
                    ? ' `[NEW IN DIFF]`'
                    : ' `[IN DIFF]`')
              : '';

          buffer.writeln(
            '### ${cluster.id}: ${cluster.category.displayName} '
            '(${cluster.bucket.displayName})$diffBadge\n',
          );
          final instCount = cluster.instances.length;
          buffer.writeln(
            '- **Estimated Savings**: `${cluster.estimatedLinesSaved}` lines '
            '($instCount instances × ~${cluster.lineCount} lines)',
          );
          buffer.writeln('- **Token Count**: `${cluster.tokenCount}` tokens\n');
          buffer.writeln('**Occurrences:**\n');

          for (final instance in cluster.instances) {
            final inDiffTag = instance.inDiff ? ' `[in diff]`' : '';
            final path = instance.filePath;
            final start = instance.startLine;
            final end = instance.endLine;
            final loc = '$path:L$start-L$end';
            final anchor = '$path#L$start-L$end';
            buffer.writeln(
              '- [`$loc`]($anchor) '
              '(${instance.lineCount} lines, ${instance.tokenCount} tokens)'
              '$inDiffTag',
            );
          }

          if (cluster.instances.isNotEmpty &&
              cluster.instances.first.snippet.isNotEmpty) {
            buffer.writeln('\n<details>');
            buffer.writeln('<summary>Preview Duplicate Code</summary>\n');
            buffer.writeln('```dart');
            buffer.writeln(cluster.instances.first.snippet);
            buffer.writeln('```');
            buffer.writeln('</details>\n');
          } else {
            buffer.writeln();
          }
        }
      }
    }

    return buffer.toString().trimRight();
  }
}
