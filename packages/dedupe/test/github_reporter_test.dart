import 'dart:io';

import 'package:checks/checks.dart';
import 'package:dedupe/dedupe.dart';
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

void main() {
  group('DedupeGitHubReporter', () {
    const inst1A = CloneInstance(
      filePath: 'lib/src/logic_a.dart',
      startLine: 10,
      endLine: 20,
      startColumn: 1,
      endColumn: 1,
      tokenCount: 40,
      lineCount: 11,
      snippet: 'void doLogic() { print("a"); }',
    );
    const inst1B = CloneInstance(
      filePath: 'lib/src/logic_b.dart',
      startLine: 10,
      endLine: 20,
      startColumn: 1,
      endColumn: 1,
      tokenCount: 40,
      lineCount: 11,
      snippet: 'void doLogic() { print("a"); }',
    );
    final clusterLogic = DuplicateCluster(
      id: 'cluster-logic',
      instances: [inst1A, inst1B],
      tokenCount: 40,
      lineCount: 11,
      category: CloneCategory.logic,
      bucket: CloneBucket.identical,
      estimatedLinesSaved: 11,
    );

    const inst2A = CloneInstance(
      filePath: 'lib/src/data_a.dart',
      startLine: 30,
      endLine: 45,
      startColumn: 1,
      endColumn: 1,
      tokenCount: 50,
      lineCount: 16,
      snippet: 'final data = [1, 2, 3];',
    );
    const inst2B = CloneInstance(
      filePath: 'lib/src/data_b.dart',
      startLine: 30,
      endLine: 45,
      startColumn: 1,
      endColumn: 1,
      tokenCount: 50,
      lineCount: 16,
      snippet: 'final data = [10, 20, 30];',
    );
    final clusterData = DuplicateCluster(
      id: 'cluster-data',
      instances: [inst2A, inst2B],
      tokenCount: 50,
      lineCount: 16,
      category: CloneCategory.data,
      bucket: CloneBucket.structural,
      estimatedLinesSaved: 16,
    );

    const inst3A = CloneInstance(
      filePath: 'lib/src/boiler_a.dart',
      startLine: 1,
      endLine: 8,
      startColumn: 1,
      endColumn: 1,
      tokenCount: 30,
      lineCount: 8,
      snippet: 'class BoilerA {}',
    );
    const inst3B = CloneInstance(
      filePath: 'lib/src/boiler_b.dart',
      startLine: 1,
      endLine: 8,
      startColumn: 1,
      endColumn: 1,
      tokenCount: 30,
      lineCount: 8,
      snippet: 'class BoilerB {}',
    );
    final clusterBoiler = DuplicateCluster(
      id: 'cluster-boiler',
      instances: [inst3A, inst3B],
      tokenCount: 30,
      lineCount: 8,
      category: CloneCategory.boilerplate,
      bucket: CloneBucket.parameterized,
      estimatedLinesSaved: 8,
    );

    const summary = DedupeSummary(
      filesAnalyzed: 6,
      totalLines: 300,
      totalTokens: 1000,
      duplicateLines: 70,
      duplicateTokens: 240,
      duplicationPercentage: 23.3,
      clusterCount: 3,
      cloneInstanceCount: 6,
      estimatedLinesSaved: 35,
    );

    const fileMetrics = [
      FileDuplicationMetric(
        filePath: 'lib/src/logic_a.dart',
        totalLines: 50,
        duplicateLines: 11,
        totalTokens: 150,
        duplicateTokens: 40,
        duplicationPercentage: 22.0,
        clusterCount: 1,
      ),
      FileDuplicationMetric(
        filePath: 'lib/src/data_a.dart',
        totalLines: 50,
        duplicateLines: 16,
        totalTokens: 150,
        duplicateTokens: 50,
        duplicationPercentage: 32.0,
        clusterCount: 1,
      ),
    ];

    final report = DedupeReport(
      version: '0.1.0-wip',
      targetPath: 'pkg/sample',
      summary: summary,
      clusters: [clusterLogic, clusterData, clusterBoiler],
      fileMetrics: fileMetrics,
    );

    test(
      'emits annotations and markdown for all clusters by default',
      () async {
        await d.dir('gh_default', [d.file('step_summary.md', '')]).create();
        final summaryFile = File(d.path('gh_default/step_summary.md'));
        final buffer = StringBuffer();

        final reporter = DedupeGitHubReporter(
          stdoutSink: buffer,
          summaryFile: summaryFile,
        );
        reporter.report(report);

        final out = buffer.toString();
        // Annotations
        check(out).contains(
          '::warning file=lib/src/logic_a.dart,line=10,endLine=20,'
          'title=Code Duplication (cluster-logic)::',
        );
        check(out).contains(
          '::warning file=lib/src/data_a.dart,line=30,endLine=45,'
          'title=Code Duplication (cluster-data)::',
        );
        check(out).contains(
          '::warning file=lib/src/boiler_a.dart,line=1,endLine=8,'
          'title=Code Duplication (cluster-boiler)::',
        );

        // Markdown
        check(out).contains('## 📊 Summary');
        check(out).contains('## 📁 File Breakdown');
        check(
          out,
        ).contains('### cluster-logic: Logic & Control Flow (Identical)');
        check(out).contains(
          '### cluster-data: Data & Declarative Boilerplate (Structural)',
        );
        check(out).contains(
          '### cluster-boiler: Scaffolding & Structural Boilerplate '
          '(Parameterized)',
        );

        // Summary File
        final summaryContent = summaryFile.readAsStringSync();
        check(
          summaryContent,
        ).contains('# 🔍 Dedupe Duplication Analysis: `pkg/sample`');
        check(summaryContent).contains('### cluster-logic');
      },
    );

    test('respects topCount filter in annotations and markdown', () {
      final buffer = StringBuffer();
      final reporter = DedupeGitHubReporter(stdoutSink: buffer, topCount: 1);
      reporter.report(report);

      final out = buffer.toString();
      check(out).contains('title=Code Duplication (cluster-logic)::');
      check(
        out,
      ).not((it) => it.contains('title=Code Duplication (cluster-data)::'));
      check(
        out,
      ).not((it) => it.contains('title=Code Duplication (cluster-boiler)::'));

      check(out).contains('### cluster-logic');
      check(out).not((it) => it.contains('### cluster-data'));
      check(out).not((it) => it.contains('### cluster-boiler'));
    });

    test('respects categoryFilter in annotations and markdown', () {
      final buffer = StringBuffer();
      final reporter = DedupeGitHubReporter(
        stdoutSink: buffer,
        categoryFilter: 'data',
      );
      reporter.report(report);

      final out = buffer.toString();
      check(
        out,
      ).not((it) => it.contains('title=Code Duplication (cluster-logic)::'));
      check(out).contains('title=Code Duplication (cluster-data)::');
      check(
        out,
      ).not((it) => it.contains('title=Code Duplication (cluster-boiler)::'));

      check(out).not((it) => it.contains('### cluster-logic'));
      check(out).contains('### cluster-data');
      check(out).not((it) => it.contains('### cluster-boiler'));
    });

    test('respects bucketFilter in annotations and markdown', () {
      final buffer = StringBuffer();
      final reporter = DedupeGitHubReporter(
        stdoutSink: buffer,
        bucketFilter: 'parameterized',
      );
      reporter.report(report);

      final out = buffer.toString();
      check(
        out,
      ).not((it) => it.contains('title=Code Duplication (cluster-logic)::'));
      check(
        out,
      ).not((it) => it.contains('title=Code Duplication (cluster-data)::'));
      check(out).contains('title=Code Duplication (cluster-boiler)::');

      check(out).not((it) => it.contains('### cluster-logic'));
      check(out).not((it) => it.contains('### cluster-data'));
      check(out).contains('### cluster-boiler');
    });

    test('respects includeFileTable=false', () {
      final buffer = StringBuffer();
      final reporter = DedupeGitHubReporter(
        stdoutSink: buffer,
        includeFileTable: false,
      );
      reporter.report(report);

      final out = buffer.toString();
      check(out).not((it) => it.contains('## 📁 File Breakdown'));
      check(out).contains('## 📊 Summary');
      check(out).contains('### cluster-logic');
    });

    test(
      'respects includeClusters=false (suppresses clusters and annotations)',
      () {
        final buffer = StringBuffer();
        final reporter = DedupeGitHubReporter(
          stdoutSink: buffer,
          includeClusters: false,
        );
        reporter.report(report);

        final out = buffer.toString();
        check(out).not((it) => it.contains('::warning'));
        check(out).not((it) => it.contains('## 🔍 Duplicate Clusters'));
        check(out).contains('## 📊 Summary');
        check(out).contains('## 📁 File Breakdown');
      },
    );

    test('propagates DedupeOptions configuration', () {
      final buffer = StringBuffer();
      final options = DedupeOptions(
        targetPath: 'pkg/sample',
        top: 1,
        categoryFilter: 'logic',
        bucketFilter: 'identical',
        includeFileTable: false,
        includeClusters: true,
      );

      final reporter = DedupeGitHubReporter(
        stdoutSink: buffer,
        options: options,
      );
      reporter.report(report);

      final out = buffer.toString();
      check(out).contains('title=Code Duplication (cluster-logic)::');
      check(
        out,
      ).not((it) => it.contains('title=Code Duplication (cluster-data)::'));
      check(out).not((it) => it.contains('## 📁 File Breakdown'));
      check(out).contains('### cluster-logic');
    });
  });
}
