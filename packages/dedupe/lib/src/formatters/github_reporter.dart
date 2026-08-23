import 'dart:io';

import 'package:analytica/analytica.dart';

import '../models.dart';
import 'markdown_formatter.dart';

/// Formatter that outputs GitHub Actions workflow commands (annotations) and
/// appends rich Markdown step summaries to `$GITHUB_STEP_SUMMARY`.
class DedupeGitHubReporter {
  final StringSink stdoutSink;
  final File? summaryFile;
  final DedupeOptions? options;
  final int topCount;
  final String categoryFilter;
  final String bucketFilter;
  final bool includeFileTable;
  final bool includeClusters;

  DedupeGitHubReporter({
    StringSink? stdoutSink,
    File? summaryFile,
    this.options,
    int? topCount,
    String? categoryFilter,
    String? bucketFilter,
    bool? includeFileTable,
    bool? includeClusters,
  }) : stdoutSink = stdoutSink ?? stdout,
       summaryFile = summaryFile ?? resolveGitHubSummaryFile(),
       topCount = topCount ?? options?.top ?? 0,
       categoryFilter = categoryFilter ?? options?.categoryFilter ?? 'all',
       bucketFilter = bucketFilter ?? options?.bucketFilter ?? 'all',
       includeFileTable = includeFileTable ?? options?.includeFileTable ?? true,
       includeClusters = includeClusters ?? options?.includeClusters ?? true;

  void report(DedupeReport report) {
    // 1. Emit GitHub Actions workflow warning annotations for duplicate
    // instances
    if (includeClusters) {
      final clusters = _filterClusters(report.clusters);
      for (final cluster in clusters) {
        for (final instance in cluster.instances) {
          final categoryName = cluster.category.displayName;
          stdoutSink.writeln(
            '::warning file=${instance.filePath},line=${instance.startLine},'
            'endLine=${instance.endLine},'
            'title=Code Duplication (${cluster.id})::'
            'Duplicate block found (${instance.lineCount} lines, '
            '${instance.tokenCount} tokens). Shared across '
            '${cluster.instances.length} occurrences in $categoryName.',
          );
        }
      }
    }

    // 2. Render Markdown report
    final formatter = MarkdownFormatter(
      topCount: topCount,
      categoryFilter: categoryFilter,
      bucketFilter: bucketFilter,
      includeFileTable: includeFileTable,
      includeClusters: includeClusters,
    );
    final markdown = formatter.format(report);
    stdoutSink.writeln(markdown);

    // 3. Write to GITHUB_STEP_SUMMARY if available
    if (summaryFile != null) {
      try {
        summaryFile!.writeAsStringSync('$markdown\n', mode: FileMode.append);
      } catch (_) {
        // Non-fatal if step summary cannot be written
      }
    }
  }

  List<DuplicateCluster> _filterClusters(List<DuplicateCluster> clusters) {
    var result = clusters;
    if (categoryFilter != 'all') {
      result = result
          .where((c) => c.category.jsonValue == categoryFilter)
          .toList();
    }
    if (bucketFilter != 'all') {
      result = result.where((c) => c.bucket.jsonValue == bucketFilter).toList();
    }
    if (topCount > 0 && result.length > topCount) {
      result = result.sublist(0, topCount);
    }
    return result;
  }
}
