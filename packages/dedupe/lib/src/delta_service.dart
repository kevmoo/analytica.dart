import 'package:analytica/git.dart';
import 'package:path/path.dart' as p;

import 'models.dart';
import 'tokenizer.dart';

/// Service for integrating Git diff information into deduplication analysis.
class DedupeDeltaService {
  final GitDiffService _gitDiffService;

  DedupeDeltaService({String? workingDirectory})
    : _gitDiffService = GitDiffService(workingDirectory: workingDirectory);

  /// Computes and returns the parsed diff against [baseRef].
  Future<List<GitFileDiff>> getParsedDiff(
    String baseRef, {
    List<String> targetPaths = const [],
  }) {
    return _gitDiffService.getParsedDiff(baseRef, targetPaths: targetPaths);
  }

  /// Maps a list of [GitFileDiff]s to a map of normalized relative file paths
  /// to their added or modified [LineRange]s.
  Map<String, List<LineRange>> extractDiffRanges(
    List<GitFileDiff> fileDiffs, {
    String? baseDir,
  }) {
    final map = <String, List<LineRange>>{};
    for (final diff in fileDiffs) {
      var path = diff.path;
      if (baseDir != null && p.isWithin(baseDir, path)) {
        path = p.relative(path, from: baseDir);
      }
      path = p.normalize(path);
      map[path] = diff.addedOrModifiedLineRanges;
    }
    return map;
  }

  /// Evaluates duplicate [clusters] against [diffRanges], annotating instances
  /// with `inDiff: true` and clusters with `intersectsDiff` and
  /// `isNewlyIntroduced`.
  ///
  /// Returns the annotated clusters, count of clusters outside diff, and
  /// calculated diff duplication percentage.
  ({
    List<DuplicateCluster> clusters,
    int clustersOutsideDiff,
    double? diffDuplicationPercent,
  })
  applyDiffToClusters({
    required List<DuplicateCluster> clusters,
    required List<TokenSequence> sequences,
    required Map<String, List<LineRange>> diffRanges,
    required bool onlyChanged,
  }) {
    if (diffRanges.isEmpty) {
      return (
        clusters: onlyChanged ? const [] : clusters,
        clustersOutsideDiff: onlyChanged ? clusters.length : 0,
        diffDuplicationPercent: 0.0,
      );
    }

    final totalChangedLinesInDiff = _computeTotalDiffLines(diffRanges);
    final duplicatedDiffLinesByFile = <String, Set<int>>{};
    final updatedClusters = <DuplicateCluster>[];
    var clustersOutside = 0;

    for (final cluster in clusters) {
      final updated = _annotateCluster(
        cluster: cluster,
        diffRanges: diffRanges,
        duplicatedDiffLinesByFile: duplicatedDiffLinesByFile,
      );

      if (!updated.intersectsDiff) {
        clustersOutside++;
      }

      if (onlyChanged && !updated.intersectsDiff) {
        continue;
      }

      updatedClusters.add(updated);
    }

    final diffDuplicationPercent = _computeDiffDuplicationPercent(
      totalChangedLinesInDiff,
      duplicatedDiffLinesByFile,
    );

    return (
      clusters: updatedClusters,
      clustersOutsideDiff: clustersOutside,
      diffDuplicationPercent: diffDuplicationPercent,
    );
  }

  static int _computeTotalDiffLines(Map<String, List<LineRange>> diffRanges) {
    var total = 0;
    for (final lineRanges in diffRanges.values) {
      for (final range in lineRanges) {
        total += range.lineCount;
      }
    }
    return total;
  }

  static DuplicateCluster _annotateCluster({
    required DuplicateCluster cluster,
    required Map<String, List<LineRange>> diffRanges,
    required Map<String, Set<int>> duplicatedDiffLinesByFile,
  }) {
    final updatedInstances = <CloneInstance>[];
    var clusterIntersectsDiff = false;
    var allInstancesInDiff = true;

    for (final instance in cluster.instances) {
      final normPath = p.normalize(instance.filePath);
      final fileRanges = diffRanges[normPath] ?? const [];

      final inDiff = _annotateInstance(
        instance: instance,
        fileRanges: fileRanges,
        normPath: normPath,
        duplicatedDiffLinesByFile: duplicatedDiffLinesByFile,
      );

      if (inDiff) {
        clusterIntersectsDiff = true;
      } else {
        allInstancesInDiff = false;
      }

      updatedInstances.add(
        CloneInstance(
          filePath: instance.filePath,
          startLine: instance.startLine,
          endLine: instance.endLine,
          startColumn: instance.startColumn,
          endColumn: instance.endColumn,
          tokenCount: instance.tokenCount,
          lineCount: instance.lineCount,
          snippet: instance.snippet,
          inDiff: inDiff,
        ),
      );
    }

    return DuplicateCluster(
      id: cluster.id,
      instances: updatedInstances,
      tokenCount: cluster.tokenCount,
      lineCount: cluster.lineCount,
      category: cluster.category,
      bucket: cluster.bucket,
      estimatedLinesSaved: cluster.estimatedLinesSaved,
      intersectsDiff: clusterIntersectsDiff,
      isNewlyIntroduced: clusterIntersectsDiff && allInstancesInDiff,
    );
  }

  static bool _annotateInstance({
    required CloneInstance instance,
    required List<LineRange> fileRanges,
    required String normPath,
    required Map<String, Set<int>> duplicatedDiffLinesByFile,
  }) {
    final inDiff = fileRanges.any(
      (r) => r.intersects(instance.startLine, instance.endLine),
    );

    if (inDiff) {
      final set = duplicatedDiffLinesByFile.putIfAbsent(
        normPath,
        () => <int>{},
      );
      for (var line = instance.startLine; line <= instance.endLine; line++) {
        if (fileRanges.any((r) => r.contains(line))) {
          set.add(line);
        }
      }
    }

    return inDiff;
  }

  static double _computeDiffDuplicationPercent(
    int totalChangedLinesInDiff,
    Map<String, Set<int>> duplicatedDiffLinesByFile,
  ) {
    var totalDuplicateLinesInDiff = 0;
    for (final set in duplicatedDiffLinesByFile.values) {
      totalDuplicateLinesInDiff += set.length;
    }

    if (totalChangedLinesInDiff > 0) {
      return (totalDuplicateLinesInDiff / totalChangedLinesInDiff) * 100;
    }
    return totalDuplicateLinesInDiff > 0 ? 100.0 : 0.0;
  }
}
