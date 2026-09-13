import '../models.dart';

/// Mixin providing duplicate cluster filtering logic for formatters and
/// reporters.
mixin ClusterFilterMixin {
  int get topCount;
  String get categoryFilter;
  String get bucketFilter;

  /// Filters [clusters] according to [categoryFilter], [bucketFilter], and
  /// [topCount].
  List<DuplicateCluster> filterClusters(List<DuplicateCluster> clusters) {
    var result = clusters;
    if (categoryFilter != 'all') {
      result =
          result.where((c) => c.category.jsonValue == categoryFilter).toList();
    }
    if (bucketFilter != 'all') {
      result =
          result.where((c) => c.bucket.jsonValue == bucketFilter).toList();
    }
    if (topCount > 0 && result.length > topCount) {
      result = result.sublist(0, topCount);
    }
    return result;
  }
}
