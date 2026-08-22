import 'dart:io';

import 'package:analytica/analytica.dart';

import '../models.dart';
import 'markdown_formatter.dart';

/// Formatter that outputs GitHub Actions workflow commands (annotations) and
/// appends rich Markdown step summaries to `$GITHUB_STEP_SUMMARY`.
class DedupeGitHubReporter {
  final StringSink stdoutSink;
  final File? summaryFile;

  DedupeGitHubReporter({StringSink? stdoutSink, File? summaryFile})
    : stdoutSink = stdoutSink ?? stdout,
      summaryFile = summaryFile ?? resolveGitHubSummaryFile();

  void report(DedupeReport report) {
    // 1. Emit GitHub Actions workflow warning annotations for duplicate
    // instances
    for (final cluster in report.clusters) {
      for (final instance in cluster.instances) {
        final categoryName = cluster.category.displayName;
        stdoutSink.writeln(
          '::warning file=${instance.filePath},line=${instance.startLine},'
          'endLine=${instance.endLine},title=Code Duplication (${cluster.id})::'
          'Duplicate block found (${instance.lineCount} lines, '
          '${instance.tokenCount} tokens). Shared across '
          '${cluster.instances.length} occurrences in $categoryName.',
        );
      }
    }

    // 2. Render Markdown report
    const formatter = MarkdownFormatter();
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
}
