/// Classification category for duplicate code clusters.
enum CloneCategory {
  logic('logic', 'Logic & Control Flow'),
  data('data', 'Data & Declarative Boilerplate'),
  boilerplate('boilerplate', 'Scaffolding & Structural Boilerplate');

  final String jsonValue;
  final String displayName;

  const CloneCategory(this.jsonValue, this.displayName);

  static CloneCategory fromJson(String value) => switch (value) {
    'logic' => logic,
    'data' => data,
    'boilerplate' => boilerplate,
    _ => throw ArgumentError.value(value, 'value', 'Unknown CloneCategory'),
  };
}

/// Structural match type / bucket for clone detection.
enum CloneBucket {
  /// Exact character and token match.
  identical('identical', 'Identical'),

  /// Matched after literal normalization (numbers, strings).
  structural('structural', 'Structural'),

  /// Matched after identifier normalization (renamed variables/fields).
  parameterized('parameterized', 'Parameterized');

  final String jsonValue;
  final String displayName;

  const CloneBucket(this.jsonValue, this.displayName);

  static CloneBucket fromJson(String value) => switch (value) {
    'identical' => identical,
    'structural' => structural,
    'parameterized' => parameterized,
    _ => throw ArgumentError.value(value, 'value', 'Unknown CloneBucket'),
  };
}

/// Output formatting mode for CLI and reports.
enum OutputFormat {
  markdown('markdown'),
  json('json'),
  github('github'),
  text('text');

  final String jsonValue;

  const OutputFormat(this.jsonValue);

  static OutputFormat fromString(String value) => switch (value) {
    'markdown' => markdown,
    'json' => json,
    'github' => github,
    'text' => text,
    _ => throw ArgumentError.value(value, 'value', 'Unknown OutputFormat'),
  };
}

/// Represents a single occurrence of duplicate code in a file.
class CloneInstance {
  final String filePath;
  final int startLine;
  final int endLine;
  final int startColumn;
  final int endColumn;
  final int tokenCount;
  final int lineCount;
  final String snippet;
  final bool inDiff;

  const CloneInstance({
    required this.filePath,
    required this.startLine,
    required this.endLine,
    required this.startColumn,
    required this.endColumn,
    required this.tokenCount,
    required this.lineCount,
    required this.snippet,
    this.inDiff = false,
  });

  factory CloneInstance.fromJson(Map<String, dynamic> json) => CloneInstance(
    filePath: json['filePath'] as String,
    startLine: json['startLine'] as int,
    endLine: json['endLine'] as int,
    startColumn: json['startColumn'] as int? ?? 1,
    endColumn: json['endColumn'] as int? ?? 1,
    tokenCount: json['tokenCount'] as int,
    lineCount: json['lineCount'] as int,
    snippet: json['snippet'] as String? ?? '',
    inDiff: json['inDiff'] as bool? ?? false,
  );

  Map<String, dynamic> toJson() => {
    'filePath': filePath,
    'startLine': startLine,
    'endLine': endLine,
    'startColumn': startColumn,
    'endColumn': endColumn,
    'tokenCount': tokenCount,
    'lineCount': lineCount,
    if (snippet.isNotEmpty) 'snippet': snippet,
    if (inDiff) 'inDiff': true,
  };

  @override
  String toString() =>
      '$filePath:$startLine-$endLine ($lineCount lines, $tokenCount tokens)';
}

/// A cluster of two or more [CloneInstance]s sharing duplicated code.
class DuplicateCluster {
  final String id;
  final List<CloneInstance> instances;
  final int tokenCount;
  final int lineCount;
  final CloneCategory category;
  final CloneBucket bucket;
  final int estimatedLinesSaved;
  final bool intersectsDiff;
  final bool isNewlyIntroduced;

  const DuplicateCluster({
    required this.id,
    required this.instances,
    required this.tokenCount,
    required this.lineCount,
    required this.category,
    required this.bucket,
    required this.estimatedLinesSaved,
    this.intersectsDiff = false,
    this.isNewlyIntroduced = false,
  });

  int get instanceCount => instances.length;

  factory DuplicateCluster.fromJson(Map<String, dynamic> json) {
    final instances = (json['instances'] as List<dynamic>)
        .map((i) => CloneInstance.fromJson(i as Map<String, dynamic>))
        .toList();
    return DuplicateCluster(
      id: json['id'] as String,
      instances: instances,
      tokenCount: json['tokenCount'] as int,
      lineCount: json['lineCount'] as int,
      category: CloneCategory.fromJson(json['category'] as String),
      bucket: CloneBucket.fromJson(json['bucket'] as String),
      estimatedLinesSaved: json['estimatedLinesSaved'] as int? ?? 0,
      intersectsDiff: json['intersectsDiff'] as bool? ?? false,
      isNewlyIntroduced: json['isNewlyIntroduced'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'instanceCount': instanceCount,
    'tokenCount': tokenCount,
    'lineCount': lineCount,
    'category': category.jsonValue,
    'bucket': bucket.jsonValue,
    'estimatedLinesSaved': estimatedLinesSaved,
    if (intersectsDiff) 'intersectsDiff': true,
    if (isNewlyIntroduced) 'isNewlyIntroduced': true,
    'instances': instances.map((i) => i.toJson()).toList(),
  };

  @override
  String toString() =>
      'Cluster $id ($category, $bucket, $instanceCount instances, '
      '$estimatedLinesSaved lines saved)';
}

/// Duplication metrics for a single analyzed file.
class FileDuplicationMetric {
  final String filePath;
  final int totalLines;
  final int duplicateLines;
  final int totalTokens;
  final int duplicateTokens;
  final double duplicationPercentage;
  final int clusterCount;

  const FileDuplicationMetric({
    required this.filePath,
    required this.totalLines,
    required this.duplicateLines,
    required this.totalTokens,
    required this.duplicateTokens,
    required this.duplicationPercentage,
    required this.clusterCount,
  });

  factory FileDuplicationMetric.fromJson(Map<String, dynamic> json) =>
      FileDuplicationMetric(
        filePath: json['filePath'] as String,
        totalLines: json['totalLines'] as int,
        duplicateLines: json['duplicateLines'] as int,
        totalTokens: json['totalTokens'] as int? ?? 0,
        duplicateTokens: json['duplicateTokens'] as int? ?? 0,
        duplicationPercentage: (json['duplicationPercentage'] as num)
            .toDouble(),
        clusterCount: json['clusterCount'] as int? ?? 0,
      );

  Map<String, dynamic> toJson() => {
    'filePath': filePath,
    'totalLines': totalLines,
    'duplicateLines': duplicateLines,
    'totalTokens': totalTokens,
    'duplicateTokens': duplicateTokens,
    'duplicationPercentage': duplicationPercentage,
    'clusterCount': clusterCount,
  };
}

/// Aggregate summary metrics for a deduplication analysis run.
class DedupeSummary {
  final int filesAnalyzed;
  final int totalLines;
  final int totalTokens;
  final int duplicateLines;
  final int duplicateTokens;
  final double duplicationPercentage;
  final double? diffDuplicationPercentage;
  final int clusterCount;
  final int cloneInstanceCount;
  final int estimatedLinesSaved;
  final int clustersOutsideDiff;

  const DedupeSummary({
    required this.filesAnalyzed,
    required this.totalLines,
    required this.totalTokens,
    required this.duplicateLines,
    required this.duplicateTokens,
    required this.duplicationPercentage,
    this.diffDuplicationPercentage,
    required this.clusterCount,
    required this.cloneInstanceCount,
    required this.estimatedLinesSaved,
    this.clustersOutsideDiff = 0,
  });

  factory DedupeSummary.fromJson(Map<String, dynamic> json) => DedupeSummary(
    filesAnalyzed: json['filesAnalyzed'] as int,
    totalLines: json['totalLines'] as int,
    totalTokens: json['totalTokens'] as int? ?? 0,
    duplicateLines: json['duplicateLines'] as int,
    duplicateTokens: json['duplicateTokens'] as int? ?? 0,
    duplicationPercentage: (json['duplicationPercentage'] as num).toDouble(),
    diffDuplicationPercentage: (json['diffDuplicationPercentage'] as num?)
        ?.toDouble(),
    clusterCount: json['clusterCount'] as int,
    cloneInstanceCount: json['cloneInstanceCount'] as int,
    estimatedLinesSaved: json['estimatedLinesSaved'] as int,
    clustersOutsideDiff: json['clustersOutsideDiff'] as int? ?? 0,
  );

  Map<String, dynamic> toJson() => {
    'filesAnalyzed': filesAnalyzed,
    'totalLines': totalLines,
    'totalTokens': totalTokens,
    'duplicateLines': duplicateLines,
    'duplicateTokens': duplicateTokens,
    'duplicationPercentage': duplicationPercentage,
    if (diffDuplicationPercentage != null)
      'diffDuplicationPercentage': diffDuplicationPercentage,
    'clusterCount': clusterCount,
    'cloneInstanceCount': cloneInstanceCount,
    'estimatedLinesSaved': estimatedLinesSaved,
    if (clustersOutsideDiff > 0) 'clustersOutsideDiff': clustersOutsideDiff,
  };
}

/// Full analysis report produced by `pkg:dedupe`.
class DedupeReport {
  final String version;
  final String targetPath;
  final DedupeSummary summary;
  final List<DuplicateCluster> clusters;
  final List<FileDuplicationMetric> fileMetrics;

  const DedupeReport({
    required this.version,
    required this.targetPath,
    required this.summary,
    required this.clusters,
    required this.fileMetrics,
  });

  factory DedupeReport.fromJson(Map<String, dynamic> json) {
    final summary = DedupeSummary.fromJson(
      json['summary'] as Map<String, dynamic>,
    );
    final clusters =
        (json['clusters'] as List<dynamic>?)
            ?.map((c) => DuplicateCluster.fromJson(c as Map<String, dynamic>))
            .toList() ??
        const [];
    final fileMetrics =
        (json['fileMetrics'] as List<dynamic>?)
            ?.map(
              (f) => FileDuplicationMetric.fromJson(f as Map<String, dynamic>),
            )
            .toList() ??
        const [];

    return DedupeReport(
      version: json['version'] as String,
      targetPath: json['targetPath'] as String? ?? '.',
      summary: summary,
      clusters: clusters,
      fileMetrics: fileMetrics,
    );
  }

  Map<String, dynamic> toJson() => {
    'version': version,
    'targetPath': targetPath,
    'summary': summary.toJson(),
    'clusters': clusters.map((c) => c.toJson()).toList(),
    'fileMetrics': fileMetrics.map((f) => f.toJson()).toList(),
  };
}

/// Configuration options for duplicate code scanning.
final class DedupeOptions {
  final String targetPath;
  final List<String> targets;
  final int minTokens;
  final int minLines;
  final bool ignoreComments;
  final bool ignoreLiterals;
  final bool ignoreIdentifiers;
  final List<String> excludePatterns;
  final List<String> includePatterns;
  final String? gitDiffBase;
  final bool onlyChanged;
  final double? failThreshold;
  final int top;
  final String categoryFilter;
  final String bucketFilter;
  final OutputFormat format;
  final String? jsonOutputPath;
  final String? sdkPath;
  final bool includeFileTable;
  final bool includeClusters;

  const DedupeOptions({
    required this.targetPath,
    this.targets = const ['lib'],
    this.minTokens = 40,
    this.minLines = 4,
    this.ignoreComments = true,
    this.ignoreLiterals = true,
    this.ignoreIdentifiers = false,
    this.excludePatterns = const [
      '**/*.g.dart',
      '**/*.freezed.dart',
      '**/*.pb.dart',
      '**/*.pbjson.dart',
      '**/*.pbenum.dart',
      '**/*.pbserver.dart',
    ],
    this.includePatterns = const ['**/*.dart'],
    this.gitDiffBase,
    this.onlyChanged = false,
    this.failThreshold,
    this.top = 0,
    this.categoryFilter = 'all',
    this.bucketFilter = 'all',
    this.format = OutputFormat.markdown,
    this.jsonOutputPath,
    this.sdkPath,
    this.includeFileTable = true,
    this.includeClusters = true,
  });
}
