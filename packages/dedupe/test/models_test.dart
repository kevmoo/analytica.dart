import 'package:checks/checks.dart';
import 'package:dedupe/dedupe.dart';
import 'package:test/test.dart';

void main() {
  group('Models Serialization & Enums', () {
    test('CloneCategory enum fromJson, fromString, and jsonValue', () {
      check(CloneCategory.logic.jsonValue).equals('logic');
      check(CloneCategory.data.jsonValue).equals('data');
      check(CloneCategory.boilerplate.jsonValue).equals('boilerplate');

      check(CloneCategory.fromJson('logic')).equals(CloneCategory.logic);
      check(CloneCategory.fromJson('data')).equals(CloneCategory.data);
      check(
        CloneCategory.fromJson('boilerplate'),
      ).equals(CloneCategory.boilerplate);

      check(CloneCategory.fromString('logic')).equals(CloneCategory.logic);
      check(CloneCategory.fromString('data')).equals(CloneCategory.data);
      check(
        CloneCategory.fromString('boilerplate'),
      ).equals(CloneCategory.boilerplate);

      check(() => CloneCategory.fromJson('invalid')).throws<ArgumentError>();
      check(() => CloneCategory.fromString('invalid')).throws<ArgumentError>();
    });

    test('CloneBucket enum fromJson, fromString, and jsonValue', () {
      check(CloneBucket.identical.jsonValue).equals('identical');
      check(CloneBucket.structural.jsonValue).equals('structural');
      check(CloneBucket.parameterized.jsonValue).equals('parameterized');
      check(CloneBucket.gapped.jsonValue).equals('gapped');

      check(CloneBucket.fromJson('identical')).equals(CloneBucket.identical);
      check(CloneBucket.fromJson('structural')).equals(CloneBucket.structural);
      check(
        CloneBucket.fromJson('parameterized'),
      ).equals(CloneBucket.parameterized);
      check(CloneBucket.fromJson('gapped')).equals(CloneBucket.gapped);

      check(CloneBucket.fromString('identical')).equals(CloneBucket.identical);
      check(
        CloneBucket.fromString('structural'),
      ).equals(CloneBucket.structural);
      check(
        CloneBucket.fromString('parameterized'),
      ).equals(CloneBucket.parameterized);
      check(CloneBucket.fromString('gapped')).equals(CloneBucket.gapped);

      check(() => CloneBucket.fromJson('invalid')).throws<ArgumentError>();
      check(() => CloneBucket.fromString('invalid')).throws<ArgumentError>();
    });

    test('OutputFormat enum fromJson, fromString, and jsonValue', () {
      check(OutputFormat.markdown.jsonValue).equals('markdown');
      check(OutputFormat.json.jsonValue).equals('json');
      check(OutputFormat.github.jsonValue).equals('github');
      check(OutputFormat.text.jsonValue).equals('text');

      check(OutputFormat.fromJson('markdown')).equals(OutputFormat.markdown);
      check(OutputFormat.fromJson('json')).equals(OutputFormat.json);
      check(OutputFormat.fromJson('github')).equals(OutputFormat.github);
      check(OutputFormat.fromJson('text')).equals(OutputFormat.text);

      check(OutputFormat.fromString('markdown')).equals(OutputFormat.markdown);
      check(OutputFormat.fromString('json')).equals(OutputFormat.json);
      check(OutputFormat.fromString('github')).equals(OutputFormat.github);
      check(OutputFormat.fromString('text')).equals(OutputFormat.text);

      check(() => OutputFormat.fromJson('invalid')).throws<ArgumentError>();
      check(() => OutputFormat.fromString('invalid')).throws<ArgumentError>();
    });

    test('CloneInstance value semantics, JSON, and toString', () {
      const instance1 = CloneInstance(
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
      const instance2 = CloneInstance(
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
      const instanceDiff = CloneInstance(
        filePath: 'lib/src/other.dart',
        startLine: 10,
        endLine: 25,
        startColumn: 1,
        endColumn: 5,
        tokenCount: 45,
        lineCount: 16,
        snippet: 'void foo() {}',
        inDiff: true,
      );

      check(instance1 == instance2).isTrue();
      check(instance1.hashCode).equals(instance2.hashCode);
      check(instance1 == instanceDiff).isFalse();

      final json = instance1.toJson();
      check(json['filePath']).equals('lib/src/util.dart');
      check(json['startLine']).equals(10);
      check(json['endLine']).equals(25);
      check(json['tokenCount']).equals(45);
      check(json['lineCount']).equals(16);
      check(json['snippet']).equals('void foo() {}');
      check(json['inDiff']).equals(true);

      final restored = CloneInstance.fromJson(json);
      check(restored == instance1).isTrue();
      check(restored.hashCode).equals(instance1.hashCode);
      check(restored.toString()).contains('lib/src/util.dart:10-25');
    });

    test('DuplicateCluster value semantics, immutability, and JSON', () {
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

      final mutableList = [instance1, instance2];
      final cluster1 = DuplicateCluster(
        id: 'cluster-1',
        instances: mutableList,
        tokenCount: 40,
        lineCount: 10,
        category: CloneCategory.logic,
        bucket: CloneBucket.identical,
        estimatedLinesSaved: 10,
        intersectsDiff: true,
        isNewlyIntroduced: false,
      );
      final cluster2 = DuplicateCluster(
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
      final clusterDiff = DuplicateCluster(
        id: 'cluster-2',
        instances: [instance1, instance2],
        tokenCount: 40,
        lineCount: 10,
        category: CloneCategory.logic,
        bucket: CloneBucket.identical,
        estimatedLinesSaved: 10,
        intersectsDiff: true,
        isNewlyIntroduced: false,
      );

      // Value semantics
      check(cluster1 == cluster2).isTrue();
      check(cluster1.hashCode).equals(cluster2.hashCode);
      check(cluster1 == clusterDiff).isFalse();

      // Defensive immutability: mutating source list does not affect cluster
      check(cluster1.instances.length).equals(2);
      expect(() => cluster1.instances.add(instance1), throwsUnsupportedError);

      final json = cluster1.toJson();
      check(json['id']).equals('cluster-1');
      check(json['instanceCount']).equals(2);
      check(json['category']).equals('logic');
      check(json['bucket']).equals('identical');
      check(json['estimatedLinesSaved']).equals(10);
      check(json['intersectsDiff']).equals(true);

      final restored = DuplicateCluster.fromJson(json);
      check(restored == cluster1).isTrue();
      check(restored.hashCode).equals(cluster1.hashCode);
      expect(() => restored.instances.add(instance1), throwsUnsupportedError);
      check(restored.toString()).contains('Cluster cluster-1');
    });

    test('FileDuplicationMetric value semantics, JSON, and toString', () {
      const metric1 = FileDuplicationMetric(
        filePath: 'lib/foo.dart',
        totalLines: 100,
        duplicateLines: 25,
        totalTokens: 500,
        duplicateTokens: 120,
        duplicationPercentage: 25.0,
        clusterCount: 2,
      );
      const metric2 = FileDuplicationMetric(
        filePath: 'lib/foo.dart',
        totalLines: 100,
        duplicateLines: 25,
        totalTokens: 500,
        duplicateTokens: 120,
        duplicationPercentage: 25.0,
        clusterCount: 2,
      );
      const metricDiff = FileDuplicationMetric(
        filePath: 'lib/bar.dart',
        totalLines: 100,
        duplicateLines: 25,
        totalTokens: 500,
        duplicateTokens: 120,
        duplicationPercentage: 25.0,
        clusterCount: 2,
      );

      check(metric1 == metric2).isTrue();
      check(metric1.hashCode).equals(metric2.hashCode);
      check(metric1 == metricDiff).isFalse();

      final json = metric1.toJson();
      check(json['filePath']).equals('lib/foo.dart');
      check(json['totalLines']).equals(100);
      check(json['duplicateLines']).equals(25);
      check(json['duplicationPercentage']).equals(25.0);
      check(json['clusterCount']).equals(2);

      final restored = FileDuplicationMetric.fromJson(json);
      check(restored == metric1).isTrue();
      check(restored.hashCode).equals(metric1.hashCode);
      check(
        restored.toString(),
      ).contains('lib/foo.dart: 25/100 duplicate lines');
    });

    test('DedupeSummary value semantics, JSON, and toString', () {
      const summary1 = DedupeSummary(
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
      const summary2 = DedupeSummary(
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
      const summaryDiff = DedupeSummary(
        filesAnalyzed: 6,
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

      check(summary1 == summary2).isTrue();
      check(summary1.hashCode).equals(summary2.hashCode);
      check(summary1 == summaryDiff).isFalse();

      final json = summary1.toJson();
      final restored = DedupeSummary.fromJson(json);
      check(restored == summary1).isTrue();
      check(restored.hashCode).equals(summary1.hashCode);
      check(restored.toString()).contains('DedupeSummary(5 files, 2 clusters');
    });

    test('DedupeReport value semantics, immutability, and JSON', () {
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
      final mutableClusters = <DuplicateCluster>[];
      final mutableMetrics = <FileDuplicationMetric>[];

      final report1 = DedupeReport(
        version: '0.1.0-wip',
        targetPath: 'packages/test',
        summary: summary,
        clusters: mutableClusters,
        fileMetrics: mutableMetrics,
      );
      final report2 = DedupeReport(
        version: '0.1.0-wip',
        targetPath: 'packages/test',
        summary: summary,
        clusters: [],
        fileMetrics: [],
      );
      final reportDiff = DedupeReport(
        version: '0.2.0',
        targetPath: 'packages/test',
        summary: summary,
        clusters: [],
        fileMetrics: [],
      );

      check(report1 == report2).isTrue();
      check(report1.hashCode).equals(report2.hashCode);
      check(report1 == reportDiff).isFalse();

      // Defensive immutability
      expect(
        () => report1.clusters.add(
          DuplicateCluster(
            id: 'c',
            instances: [],
            tokenCount: 1,
            lineCount: 1,
            category: CloneCategory.logic,
            bucket: CloneBucket.identical,
            estimatedLinesSaved: 1,
          ),
        ),
        throwsUnsupportedError,
      );
      expect(
        () => report1.fileMetrics.add(
          const FileDuplicationMetric(
            filePath: 'f',
            totalLines: 1,
            duplicateLines: 0,
            totalTokens: 1,
            duplicateTokens: 0,
            duplicationPercentage: 0,
            clusterCount: 0,
          ),
        ),
        throwsUnsupportedError,
      );

      final json = report1.toJson();
      check(json['version']).equals('0.1.0-wip');
      check(json['targetPath']).equals('packages/test');

      final restored = DedupeReport.fromJson(json);
      check(restored == report1).isTrue();
      check(restored.hashCode).equals(report1.hashCode);
      expect(
        () => restored.clusters.add(
          DuplicateCluster(
            id: 'c',
            instances: [],
            tokenCount: 1,
            lineCount: 1,
            category: CloneCategory.logic,
            bucket: CloneBucket.identical,
            estimatedLinesSaved: 1,
          ),
        ),
        throwsUnsupportedError,
      );
      check(restored.toString()).contains('DedupeReport(version: 0.1.0-wip');
    });

    test('DedupeOptions value semantics, defaults, and immutability', () {
      final mutableTargets = ['lib'];
      final mutableExcludes = ['**/*.g.dart'];
      final mutableIncludes = ['**/*.dart'];

      final options1 = DedupeOptions(
        targetPath: 'packages/test',
        targets: mutableTargets,
        excludePatterns: mutableExcludes,
        includePatterns: mutableIncludes,
      );
      final options2 = DedupeOptions(
        targetPath: 'packages/test',
        targets: ['lib'],
        excludePatterns: ['**/*.g.dart'],
        includePatterns: ['**/*.dart'],
      );
      final optionsDiff = DedupeOptions(
        targetPath: 'packages/other',
        targets: ['lib'],
        excludePatterns: ['**/*.g.dart'],
        includePatterns: ['**/*.dart'],
      );

      check(options1 == options2).isTrue();
      check(options1.hashCode).equals(options2.hashCode);
      check(options1 == optionsDiff).isFalse();

      // Defensive immutability
      expect(() => options1.targets.add('bin'), throwsUnsupportedError);
      expect(
        () => options1.excludePatterns.add('*.tmp'),
        throwsUnsupportedError,
      );
      expect(
        () => options1.includePatterns.add('*.dart'),
        throwsUnsupportedError,
      );

      check(
        options1.toString(),
      ).contains('DedupeOptions(targetPath: packages/test');
    });
  });
}
