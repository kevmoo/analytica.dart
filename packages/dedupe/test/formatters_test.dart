import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:dedupe/dedupe.dart';
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

void main() {
  group('Formatters', () {
    const instance1 = CloneInstance(
      filePath: 'lib/src/a.dart',
      startLine: 10,
      endLine: 25,
      startColumn: 1,
      endColumn: 2,
      tokenCount: 45,
      lineCount: 16,
      snippet: 'void duplicatedMethod() {\n  print(1);\n}',
      inDiff: true,
    );

    const instance2 = CloneInstance(
      filePath: 'lib/src/b.dart',
      startLine: 20,
      endLine: 35,
      startColumn: 1,
      endColumn: 2,
      tokenCount: 45,
      lineCount: 16,
      snippet: 'void duplicatedMethod() {\n  print(1);\n}',
      inDiff: false,
    );

    const cluster = DuplicateCluster(
      id: 'cluster-1',
      instances: [instance1, instance2],
      tokenCount: 45,
      lineCount: 16,
      category: CloneCategory.logic,
      bucket: CloneBucket.identical,
      estimatedLinesSaved: 16,
      intersectsDiff: true,
      isNewlyIntroduced: false,
    );

    const summary = DedupeSummary(
      filesAnalyzed: 2,
      totalLines: 100,
      totalTokens: 500,
      duplicateLines: 32,
      duplicateTokens: 90,
      duplicationPercentage: 32.0,
      diffDuplicationPercentage: 25.0,
      clusterCount: 1,
      cloneInstanceCount: 2,
      estimatedLinesSaved: 16,
    );

    const fileMetric1 = FileDuplicationMetric(
      filePath: 'lib/src/a.dart',
      totalLines: 50,
      duplicateLines: 16,
      totalTokens: 250,
      duplicateTokens: 45,
      duplicationPercentage: 32.0,
      clusterCount: 1,
    );

    const report = DedupeReport(
      version: '0.1.0-wip',
      targetPath: 'packages/test',
      summary: summary,
      clusters: [cluster],
      fileMetrics: [fileMetric1],
    );

    test('JsonFormatter emits valid JSON matching report schema', () {
      const formatter = JsonFormatter();
      final output = formatter.format(report);

      final decoded = jsonDecode(output) as Map<String, dynamic>;
      check(decoded['version']).equals('0.1.0-wip');
      final summaryMap = decoded['summary'] as Map<String, dynamic>;
      check(summaryMap['duplicationPercentage']).equals(32.0);
      check((decoded['clusters'] as List<dynamic>).length).equals(1);
    });

    test('MarkdownFormatter renders rich report with summary, file table, '
        'and clusters', () {
      const formatter = MarkdownFormatter();
      final output = formatter.format(report);

      check(
        output,
      ).contains('# 🔍 Dedupe Duplication Analysis: `packages/test`');
      check(output).contains('| **Files Analyzed** | `2` |');
      check(output).contains('| **Duplicate Lines** | `32` (32.0%) |');
      check(output).contains('| **Diff Duplication** | 25.0% |');
      check(output).contains('## 📁 File Breakdown');
      check(output).contains('`lib/src/a.dart`');
      check(
        output,
      ).contains('### cluster-1: Logic & Control Flow (Identical) `[IN DIFF]`');
      check(output).contains('`[in diff]`');
      check(output).contains('<details>');
      check(output).contains('void duplicatedMethod()');
    });

    test('MarkdownFormatter handles zero duplicate report cleanly', () {
      const cleanSummary = DedupeSummary(
        filesAnalyzed: 5,
        totalLines: 300,
        totalTokens: 1200,
        duplicateLines: 0,
        duplicateTokens: 0,
        duplicationPercentage: 0.0,
        clusterCount: 0,
        cloneInstanceCount: 0,
        estimatedLinesSaved: 0,
      );

      const cleanReport = DedupeReport(
        version: '0.1.0-wip',
        targetPath: 'clean_pkg',
        summary: cleanSummary,
        clusters: [],
        fileMetrics: [],
      );

      const formatter = MarkdownFormatter();
      final output = formatter.format(cleanReport);

      check(output).contains('## ✨ Zero Code Duplication Detected');
    });

    test('TextFormatter renders concise terminal output', () {
      const formatter = TextFormatter();
      final output = formatter.format(report);

      check(output).contains('Dedupe Duplication Summary: packages/test');
      check(output).contains('Files Analyzed:          2');
      check(output).contains('Duplicate Lines:         32 (32.0%)');
      check(output).contains('Top Duplicate Clusters:');
      check(output).contains('[cluster-1] Logic & Control Flow (Identical)');
    });

    test(
      'DedupeGitHubReporter emits annotations and writes to summary file',
      () async {
        await d.dir('gh_test', [d.file('step_summary.md', '')]).create();

        final summaryFile = File(d.path('gh_test/step_summary.md'));
        final stringBuffer = StringBuffer();
        final reporter = DedupeGitHubReporter(
          stdoutSink: stringBuffer,
          summaryFile: summaryFile,
        );

        reporter.report(report);

        final stdoutText = stringBuffer.toString();
        check(
          stdoutText,
        ).contains('::warning file=lib/src/a.dart,line=10,endLine=25');

        final summaryText = summaryFile.readAsStringSync();
        check(
          summaryText,
        ).contains('# 🔍 Dedupe Duplication Analysis: `packages/test`');
      },
    );
  });
}
