import 'package:analytica/git.dart';
import 'package:checks/checks.dart';
import 'package:dedupe/dedupe.dart';
import 'package:test/test.dart';

void main() {
  group('DedupeDeltaService', () {
    test('extractDiffRanges normalizes paths and extracts line ranges', () {
      final service = DedupeDeltaService();
      final diffs = [
        const GitFileDiff(
          newPath: 'packages/core/lib/src/util.dart',
          hunks: [
            DiffHunk(
              oldStart: 10,
              oldCount: 5,
              newStart: 10,
              newCount: 8,
              lines: [],
              addedOrModifiedRanges: [LineRange(12, 16)],
            ),
          ],
        ),
      ];

      final ranges = service.extractDiffRanges(diffs, baseDir: 'packages/core');

      check(ranges['lib/src/util.dart']).isNotNull();
      check(
        ranges['lib/src/util.dart']!.single,
      ).equals(const LineRange(12, 16));
    });

    test(
      'extractDiffRanges resolves repo-relative diffs against absolute baseDir and repoRoot',
      () {
        final service = DedupeDeltaService();
        final diffs = [
          const GitFileDiff(
            newPath: 'packages/core/lib/src/util.dart',
            hunks: [
              DiffHunk(
                oldStart: 10,
                oldCount: 5,
                newStart: 10,
                newCount: 8,
                lines: [],
                addedOrModifiedRanges: [LineRange(12, 16)],
              ),
            ],
          ),
          const GitFileDiff(
            newPath: 'packages/other/lib/other.dart',
            hunks: [
              DiffHunk(
                oldStart: 1,
                oldCount: 1,
                newStart: 1,
                newCount: 5,
                lines: [],
                addedOrModifiedRanges: [LineRange(1, 5)],
              ),
            ],
          ),
        ];

        final ranges = service.extractDiffRanges(
          diffs,
          baseDir: '/repo/root/packages/core',
          repoRoot: '/repo/root',
        );

        check(ranges['lib/src/util.dart']).isNotNull();
        check(
          ranges['lib/src/util.dart']!.single,
        ).equals(const LineRange(12, 16));
        check(ranges.containsKey('packages/other/lib/other.dart')).isFalse();
      },
    );

    test(
      'applyDiffToClusters annotates instances and computes diff duplication',
      () {
        final service = DedupeDeltaService();

        const instance1 = CloneInstance(
          filePath: 'lib/util_a.dart',
          startLine: 10,
          endLine: 20,
          startColumn: 1,
          endColumn: 2,
          tokenCount: 40,
          lineCount: 11,
          snippet: 'code',
        );

        const instance2 = CloneInstance(
          filePath: 'lib/util_b.dart',
          startLine: 30,
          endLine: 40,
          startColumn: 1,
          endColumn: 2,
          tokenCount: 40,
          lineCount: 11,
          snippet: 'code',
        );

        const cluster = DuplicateCluster(
          id: 'cluster-1',
          instances: [instance1, instance2],
          tokenCount: 40,
          lineCount: 11,
          category: CloneCategory.logic,
          bucket: CloneBucket.identical,
          estimatedLinesSaved: 11,
        );

        // Diff modifies lines 15-25 in util_a.dart (overlaps instance1)
        final diffRanges = {
          'lib/util_a.dart': [const LineRange(15, 25)],
        };

        final result = service.applyDiffToClusters(
          clusters: [cluster],
          sequences: [],
          diffRanges: diffRanges,
          onlyChanged: false,
        );

        check(result.clusters.length).equals(1);
        final updatedCluster = result.clusters.first;
        check(updatedCluster.intersectsDiff).isTrue();
        check(updatedCluster.isNewlyIntroduced).isFalse();
        check(updatedCluster.instances.first.inDiff).isTrue();
        check(updatedCluster.instances.last.inDiff).isFalse();
        check(result.diffDuplicationPercent).isNotNull();
        check(result.diffDuplicationPercent!).isGreaterThan(0.0);
      },
    );

    test('filters out untouched clusters when onlyChanged is true', () {
      final service = DedupeDeltaService();

      const instance1 = CloneInstance(
        filePath: 'lib/old_a.dart',
        startLine: 1,
        endLine: 10,
        startColumn: 1,
        endColumn: 2,
        tokenCount: 40,
        lineCount: 10,
        snippet: 'code',
      );
      const instance2 = CloneInstance(
        filePath: 'lib/old_b.dart',
        startLine: 1,
        endLine: 10,
        startColumn: 1,
        endColumn: 2,
        tokenCount: 40,
        lineCount: 10,
        snippet: 'code',
      );

      const cluster = DuplicateCluster(
        id: 'cluster-legacy',
        instances: [instance1, instance2],
        tokenCount: 40,
        lineCount: 10,
        category: CloneCategory.logic,
        bucket: CloneBucket.identical,
        estimatedLinesSaved: 10,
      );

      // Diff modifies unrelated file
      final diffRanges = {
        'lib/new_file.dart': [const LineRange(1, 5)],
      };

      final result = service.applyDiffToClusters(
        clusters: [cluster],
        sequences: [],
        diffRanges: diffRanges,
        onlyChanged: true,
      );

      check(result.clusters).isEmpty();
      check(result.clustersOutsideDiff).equals(1);
    });
  });
}
