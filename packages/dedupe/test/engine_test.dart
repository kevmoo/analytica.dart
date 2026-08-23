import 'dart:io';

import 'package:checks/checks.dart';
import 'package:dedupe/dedupe.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('DedupeEngine', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('dedupe_engine_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
      'analyzes a directory and detects duplicate clusters across files',
      () async {
        const codeA = '''
void handleRequest(String route, Map<String, String> headers) {
  if (route.isEmpty) {
    throw ArgumentError('Route cannot be empty');
  }
  print('Handling route: \$route with \${headers.length} headers');
  for (final entry in headers.entries) {
    print('Header: \${entry.key} = \${entry.value}');
  }
}
''';

        const codeB = '''
void handleRequest(String route, Map<String, String> headers) {
  if (route.isEmpty) {
    throw ArgumentError('Route cannot be empty');
  }
  print('Handling route: \$route with \${headers.length} headers');
  for (final entry in headers.entries) {
    print('Header: \${entry.key} = \${entry.value}');
  }
}
''';

        final libDir = Directory(p.join(tempDir.path, 'lib'))..createSync();
        File(p.join(libDir.path, 'service_a.dart')).writeAsStringSync(codeA);
        File(p.join(libDir.path, 'service_b.dart')).writeAsStringSync(codeB);

        final engine = DedupeEngine(
          DedupeOptions(targetPath: tempDir.path, minTokens: 20, minLines: 4),
        );

        final report = await engine.analyze();

        check(report.summary.filesAnalyzed).equals(2);
        check(report.summary.clusterCount).equals(1);
        check(report.summary.cloneInstanceCount).equals(2);
        check(report.summary.duplicateLines > 0).equals(true);
        check(report.summary.duplicationPercentage > 0).equals(true);
        check(report.summary.estimatedLinesSaved > 0).equals(true);
        check(report.clusters.length).equals(1);

        final cluster = report.clusters.first;
        check(cluster.instances.length).equals(2);
        check(cluster.bucket).equals(CloneBucket.identical);
        check(cluster.category).equals(CloneCategory.logic);
      },
    );

    test('filters out excluded file patterns', () async {
      const duplicateCode = '''
void calculateSum(int a, int b) {
  final res = a + b;
  print('Result is \$res');
  print('Double is \${res * 2}');
}
''';

      final libDir = Directory(p.join(tempDir.path, 'lib'))..createSync();
      File(p.join(libDir.path, 'normal.dart')).writeAsStringSync(duplicateCode);
      File(
        p.join(libDir.path, 'generated.g.dart'),
      ).writeAsStringSync(duplicateCode);

      final engine = DedupeEngine(
        DedupeOptions(
          targetPath: tempDir.path,
          minTokens: 10,
          minLines: 3,
          excludePatterns: ['**/*.g.dart'],
        ),
      );

      final report = await engine.analyze();

      // Only normal.dart is analyzed, so no duplicates across files can be
      // found.
      check(report.summary.filesAnalyzed).equals(1);
      check(report.summary.clusterCount).equals(0);
    });

    test('handles empty directories cleanly', () async {
      final engine = DedupeEngine(
        DedupeOptions(targetPath: tempDir.path, minTokens: 20, minLines: 4),
      );

      final report = await engine.analyze();

      check(report.summary.filesAnalyzed).equals(0);
      check(report.summary.totalLines).equals(0);
      check(report.summary.duplicateLines).equals(0);
      check(report.summary.duplicationPercentage).equals(0.0);
      check(report.summary.clusterCount).equals(0);
      check(report.clusters.isEmpty).equals(true);
    });

    test('handles directories with single non-duplicate file', () async {
      const code = '''
void singleFunction() {
  print('Hello world');
}
''';
      final libDir = Directory(p.join(tempDir.path, 'lib'))..createSync();
      File(p.join(libDir.path, 'main.dart')).writeAsStringSync(code);

      final engine = DedupeEngine(
        DedupeOptions(targetPath: tempDir.path, minTokens: 20, minLines: 4),
      );

      final report = await engine.analyze();

      check(report.summary.filesAnalyzed).equals(1);
      check(report.summary.duplicateLines).equals(0);
      check(report.summary.clusterCount).equals(0);
    });

    test('computes estimatedLinesSaved correctly across 2, 3, and 4 duplicate '
        'files', () async {
      const fourteenLineBlock = '''
void handleRecord(String id, int count, double weight) {
  if (id.isEmpty) {
    throw ArgumentError('id is empty');
  }
  if (count <= 0) {
    throw ArgumentError('count is non-positive');
  }
  if (weight < 0.0) {
    throw ArgumentError('weight is negative');
  }
  final density = count / weight;
  print('Processing record: \$id, density: \$density');
  print('Recording transaction to audit trail');
}
''';

      final libDir = Directory(p.join(tempDir.path, 'lib'))..createSync();
      File(
        p.join(libDir.path, 'file1.dart'),
      ).writeAsStringSync(fourteenLineBlock);
      File(
        p.join(libDir.path, 'file2.dart'),
      ).writeAsStringSync(fourteenLineBlock);

      // 2 files: 28 duplicate lines, 14 lines saved
      final engine2 = DedupeEngine(
        DedupeOptions(targetPath: tempDir.path, minTokens: 20, minLines: 4),
      );
      final report2 = await engine2.analyze();
      check(report2.summary.filesAnalyzed).equals(2);
      check(report2.summary.clusterCount).equals(1);
      check(report2.summary.duplicateLines).equals(28);
      check(report2.summary.estimatedLinesSaved).equals(14);

      // 3 files: 42 duplicate lines, 28 lines saved
      File(
        p.join(libDir.path, 'file3.dart'),
      ).writeAsStringSync(fourteenLineBlock);
      final engine3 = DedupeEngine(
        DedupeOptions(targetPath: tempDir.path, minTokens: 20, minLines: 4),
      );
      final report3 = await engine3.analyze();
      check(report3.summary.filesAnalyzed).equals(3);
      check(report3.summary.clusterCount).equals(1);
      check(report3.summary.duplicateLines).equals(42);
      check(report3.summary.estimatedLinesSaved).equals(28);

      // 4 files: 56 duplicate lines, 42 lines saved
      File(
        p.join(libDir.path, 'file4.dart'),
      ).writeAsStringSync(fourteenLineBlock);
      final engine4 = DedupeEngine(
        DedupeOptions(targetPath: tempDir.path, minTokens: 20, minLines: 4),
      );
      final report4 = await engine4.analyze();
      check(report4.summary.filesAnalyzed).equals(4);
      check(report4.summary.clusterCount).equals(1);
      check(report4.summary.duplicateLines).equals(56);
      check(report4.summary.estimatedLinesSaved).equals(42);
    });

    test(
      'handles overlapping clusters without over-counting estimatedLinesSaved',
      () async {
        const code1 = '''
void pipeline1() {
  print('L1');
  print('L2');
  print('L3');
  print('L4');
  print('L5');
  print('L6');
}
''';
        const code2 = '''
void pipeline2() {
  print('L1');
  print('L2');
  print('L3');
  print('L4');
  print('L5');
  print('L6');
}
''';
        final libDir = Directory(p.join(tempDir.path, 'lib'))..createSync();
        File(p.join(libDir.path, 'p1.dart')).writeAsStringSync(code1);
        File(p.join(libDir.path, 'p2.dart')).writeAsStringSync(code2);

        final engine = DedupeEngine(
          DedupeOptions(targetPath: tempDir.path, minTokens: 10, minLines: 4),
        );
        final report = await engine.analyze();

        check(
          report.summary.estimatedLinesSaved,
        ).isLessThan(report.summary.duplicateLines);
        check(report.summary.estimatedLinesSaved).isGreaterThan(0);
      },
    );
  });
}
