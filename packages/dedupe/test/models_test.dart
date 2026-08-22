import 'package:checks/checks.dart';
import 'package:dedupe/dedupe.dart';
import 'package:test/test.dart';

void main() {
  group('Models Serialization & Enums', () {
    test('CloneCategory enum fromJson and jsonValue', () {
      check(CloneCategory.logic.jsonValue).equals('logic');
      check(CloneCategory.data.jsonValue).equals('data');
      check(CloneCategory.boilerplate.jsonValue).equals('boilerplate');

      check(CloneCategory.fromJson('logic')).equals(CloneCategory.logic);
      check(CloneCategory.fromJson('data')).equals(CloneCategory.data);
      check(
        CloneCategory.fromJson('boilerplate'),
      ).equals(CloneCategory.boilerplate);

      check(() => CloneCategory.fromJson('invalid')).throws<ArgumentError>();
    });

    test('CloneBucket enum fromJson and jsonValue', () {
      check(CloneBucket.identical.jsonValue).equals('identical');
      check(CloneBucket.structural.jsonValue).equals('structural');
      check(CloneBucket.parameterized.jsonValue).equals('parameterized');

      check(CloneBucket.fromJson('identical')).equals(CloneBucket.identical);
      check(CloneBucket.fromJson('structural')).equals(CloneBucket.structural);
      check(
        CloneBucket.fromJson('parameterized'),
      ).equals(CloneBucket.parameterized);

      check(() => CloneBucket.fromJson('invalid')).throws<ArgumentError>();
    });

    test('OutputFormat enum fromString and jsonValue', () {
      check(OutputFormat.markdown.jsonValue).equals('markdown');
      check(OutputFormat.json.jsonValue).equals('json');
      check(OutputFormat.github.jsonValue).equals('github');
      check(OutputFormat.text.jsonValue).equals('text');

      check(OutputFormat.fromString('markdown')).equals(OutputFormat.markdown);
      check(OutputFormat.fromString('json')).equals(OutputFormat.json);
      check(OutputFormat.fromString('github')).equals(OutputFormat.github);
      check(OutputFormat.fromString('text')).equals(OutputFormat.text);

      check(() => OutputFormat.fromString('invalid')).throws<ArgumentError>();
    });

    test('CloneInstance JSON roundtrip', () {
      const instance = CloneInstance(
        filePath: 'lib/src/util.dart',
        startLine: 10,
        endLine: 25,
        startColumn: 1,
        endColumn: 5,
        tokenCount: 45,
        lineCount: 16,
        snippet: 'void foo() {}',
        inDiff: true,
      );

      final json = instance.toJson();
      check(json['filePath']).equals('lib/src/util.dart');
      check(json['startLine']).equals(10);
      check(json['endLine']).equals(25);
      check(json['tokenCount']).equals(45);
      check(json['lineCount']).equals(16);
      check(json['snippet']).equals('void foo() {}');
      check(json['inDiff']).equals(true);

      final restored = CloneInstance.fromJson(json);
      check(restored.filePath).equals(instance.filePath);
      check(restored.startLine).equals(instance.startLine);
      check(restored.endLine).equals(instance.endLine);
      check(restored.tokenCount).equals(instance.tokenCount);
      check(restored.lineCount).equals(instance.lineCount);
      check(restored.snippet).equals(instance.snippet);
      check(restored.inDiff).equals(instance.inDiff);
      check(restored.toString()).contains('lib/src/util.dart:10-25');
    });

    test('DuplicateCluster JSON roundtrip', () {
      const instance1 = CloneInstance(
        filePath: 'lib/a.dart',
        startLine: 1,
        endLine: 10,
        startColumn: 1,
        endColumn: 2,
        tokenCount: 40,
        lineCount: 10,
        snippet: 'int a = 1;',
        inDiff: true,
      );
      const instance2 = CloneInstance(
        filePath: 'lib/b.dart',
        startLine: 5,
        endLine: 14,
        startColumn: 1,
        endColumn: 2,
        tokenCount: 40,
        lineCount: 10,
        snippet: 'int a = 1;',
        inDiff: false,
      );

      const cluster = DuplicateCluster(
        id: 'cluster-1',
        instances: [instance1, instance2],
        tokenCount: 40,
        lineCount: 10,
        category: CloneCategory.logic,
        bucket: CloneBucket.identical,
        estimatedLinesSaved: 10,
        intersectsDiff: true,
        isNewlyIntroduced: false,
      );

      check(cluster.instanceCount).equals(2);
      final json = cluster.toJson();
      check(json['id']).equals('cluster-1');
      check(json['instanceCount']).equals(2);
      check(json['category']).equals('logic');
      check(json['bucket']).equals('identical');
      check(json['estimatedLinesSaved']).equals(10);
      check(json['intersectsDiff']).equals(true);

      final restored = DuplicateCluster.fromJson(json);
      check(restored.id).equals(cluster.id);
      check(restored.instanceCount).equals(cluster.instanceCount);
      check(restored.category).equals(cluster.category);
      check(restored.bucket).equals(cluster.bucket);
      check(restored.estimatedLinesSaved).equals(cluster.estimatedLinesSaved);
      check(restored.intersectsDiff).equals(cluster.intersectsDiff);
      check(restored.isNewlyIntroduced).equals(cluster.isNewlyIntroduced);
      check(restored.toString()).contains('Cluster cluster-1');
    });

    test('FileDuplicationMetric JSON roundtrip', () {
      const metric = FileDuplicationMetric(
        filePath: 'lib/foo.dart',
        totalLines: 100,
        duplicateLines: 25,
        totalTokens: 500,
        duplicateTokens: 120,
        duplicationPercentage: 25.0,
        clusterCount: 2,
      );

      final json = metric.toJson();
      check(json['filePath']).equals('lib/foo.dart');
      check(json['totalLines']).equals(100);
      check(json['duplicateLines']).equals(25);
      check(json['duplicationPercentage']).equals(25.0);
      check(json['clusterCount']).equals(2);

      final restored = FileDuplicationMetric.fromJson(json);
      check(restored.filePath).equals(metric.filePath);
      check(restored.totalLines).equals(metric.totalLines);
      check(restored.duplicateLines).equals(metric.duplicateLines);
      check(
        restored.duplicationPercentage,
      ).equals(metric.duplicationPercentage);
      check(restored.clusterCount).equals(metric.clusterCount);
    });

    test('DedupeReport JSON roundtrip', () {
      const summary = DedupeSummary(
        filesAnalyzed: 5,
        totalLines: 500,
        totalTokens: 2500,
        duplicateLines: 50,
        duplicateTokens: 250,
        duplicationPercentage: 10.0,
        diffDuplicationPercentage: 12.5,
        clusterCount: 2,
        cloneInstanceCount: 4,
        estimatedLinesSaved: 25,
        clustersOutsideDiff: 1,
      );

      const report = DedupeReport(
        version: '0.1.0-wip',
        targetPath: 'packages/test',
        summary: summary,
        clusters: [],
        fileMetrics: [],
      );

      final json = report.toJson();
      check(json['version']).equals('0.1.0-wip');
      check(json['targetPath']).equals('packages/test');

      final restored = DedupeReport.fromJson(json);
      check(restored.version).equals(report.version);
      check(restored.targetPath).equals(report.targetPath);
      check(restored.summary.filesAnalyzed).equals(5);
      check(restored.summary.duplicationPercentage).equals(10.0);
      check(restored.summary.diffDuplicationPercentage).equals(12.5);
    });
  });
}
