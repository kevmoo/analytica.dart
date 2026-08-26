import 'package:analytica/analyzer.dart';

/// Standard code-generation, binding, and test mock exclusions for duplication
/// analysis.
const List<String> defaultDartExclusions = [
  ...PathFilter.defaultGeneratedPatterns,
  '**/*_bindings.dart',
  '**/native_*.dart',
  '**/jni_*.dart',
];

/// Classification category for duplicate code clusters.
enum CloneCategory {
  /// Logic and control flow duplication (if statements, loops, algorithms).
  logic('logic', 'Logic & Control Flow'),

  /// Data definitions, literals, maps, and declarative boilerplate.
  data('data', 'Data & Declarative Boilerplate'),

  /// Structural boilerplate and scaffolding (class structures, setups).
  boilerplate('boilerplate', 'Scaffolding & Structural Boilerplate');

  final String jsonValue;
  final String displayName;

  const CloneCategory(this.jsonValue, this.displayName);

  /// Parses a [CloneCategory] from its JSON string representation.
  static CloneCategory fromJson(String value) => switch (value) {
    'logic' => logic,
    'data' => data,
    'boilerplate' => boilerplate,
    _ => throw ArgumentError.value(value, 'value', 'Unknown CloneCategory'),
  };

  /// Parses a [CloneCategory] from a string representation.
  static CloneCategory fromString(String value) => fromJson(value);
}

/// Structural match type / bucket for clone detection.
enum CloneBucket {
  /// Exact character and token match.
  identical('identical', 'Identical'),

  /// Matched after literal normalization (numbers, strings).
  structural('structural', 'Structural'),

  /// Matched after identifier normalization (renamed variables/fields).
  parameterized('parameterized', 'Parameterized'),

  /// Matched with minor statement insertions, deletions, or gaps via MinHash.
  gapped('gapped', 'Gapped (Near-Miss)');

  final String jsonValue;
  final String displayName;

  const CloneBucket(this.jsonValue, this.displayName);

  /// Parses a [CloneBucket] from its JSON string representation.
  static CloneBucket fromJson(String value) => switch (value) {
    'identical' => identical,
    'structural' => structural,
    'parameterized' => parameterized,
    'gapped' => gapped,
    _ => throw ArgumentError.value(value, 'value', 'Unknown CloneBucket'),
  };

  /// Parses a [CloneBucket] from a string representation.
  static CloneBucket fromString(String value) => fromJson(value);
}

/// Output formatting mode for CLI and reports.
enum OutputFormat {
  /// Formats the report as human-readable GitHub Flavored Markdown.
  markdown('markdown'),

  /// Formats the report as machine-readable JSON.
  json('json'),

  /// Emits GitHub Actions workflow commands and PR review annotations.
  github('github'),

  /// Formats the report as concise, plain ASCII text.
  text('text');

  final String jsonValue;

  const OutputFormat(this.jsonValue);

  /// Parses an [OutputFormat] from its JSON string representation.
  static OutputFormat fromJson(String value) => fromString(value);

  /// Parses an [OutputFormat] from a string representation.
  static OutputFormat fromString(String value) => switch (value) {
    'markdown' => markdown,
    'json' => json,
    'github' => github,
    'text' => text,
    _ => throw ArgumentError.value(value, 'value', 'Unknown OutputFormat'),
  };
}

/// Represents a single occurrence of duplicate code in a file.
final class CloneInstance {
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
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CloneInstance &&
          filePath == other.filePath &&
          startLine == other.startLine &&
          endLine == other.endLine &&
          startColumn == other.startColumn &&
          endColumn == other.endColumn &&
          tokenCount == other.tokenCount &&
          lineCount == other.lineCount &&
          snippet == other.snippet &&
          inDiff == other.inDiff;

  @override
  int get hashCode => Object.hash(
    filePath,
    startLine,
    endLine,
    startColumn,
    endColumn,
    tokenCount,
    lineCount,
    snippet,
    inDiff,
  );

  @override
  String toString() =>
      '$filePath:$startLine-$endLine ($lineCount lines, $tokenCount tokens)';
}

/// A cluster of two or more [CloneInstance]s sharing duplicated code.
final class DuplicateCluster {
  final String id;
  final List<CloneInstance> instances;
  final int tokenCount;
  final int lineCount;
  final CloneCategory category;
  final CloneBucket bucket;
  final int estimatedLinesSaved;
  final bool intersectsDiff;
  final bool isNewlyIntroduced;

  DuplicateCluster({
    required this.id,
    required List<CloneInstance> instances,
    required this.tokenCount,
    required this.lineCount,
    required this.category,
    required this.bucket,
    required this.estimatedLinesSaved,
    this.intersectsDiff = false,
    this.isNewlyIntroduced = false,
  }) : instances = List.unmodifiable(instances);

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
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DuplicateCluster &&
          id == other.id &&
          _listEquals(instances, other.instances) &&
          tokenCount == other.tokenCount &&
          lineCount == other.lineCount &&
          category == other.category &&
          bucket == other.bucket &&
          estimatedLinesSaved == other.estimatedLinesSaved &&
          intersectsDiff == other.intersectsDiff &&
          isNewlyIntroduced == other.isNewlyIntroduced;

  @override
  int get hashCode => Object.hash(
    id,
    Object.hashAll(instances),
    tokenCount,
    lineCount,
    category,
    bucket,
    estimatedLinesSaved,
    intersectsDiff,
    isNewlyIntroduced,
  );

  @override
  String toString() =>
      'Cluster $id ($category, $bucket, $instanceCount instances, '
      '$estimatedLinesSaved lines saved)';
}

/// Duplication metrics for a single analyzed file.
final class FileDuplicationMetric {
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

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FileDuplicationMetric &&
          filePath == other.filePath &&
          totalLines == other.totalLines &&
          duplicateLines == other.duplicateLines &&
          totalTokens == other.totalTokens &&
          duplicateTokens == other.duplicateTokens &&
          duplicationPercentage == other.duplicationPercentage &&
          clusterCount == other.clusterCount;

  @override
  int get hashCode => Object.hash(
    filePath,
    totalLines,
    duplicateLines,
    totalTokens,
    duplicateTokens,
    duplicationPercentage,
    clusterCount,
  );

  @override
  String toString() =>
      '$filePath: $duplicateLines/$totalLines duplicate lines '
      '(${duplicationPercentage.toStringAsFixed(1)}%)';
}

/// Aggregate summary metrics for a deduplication analysis run.
final class DedupeSummary {
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

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DedupeSummary &&
          filesAnalyzed == other.filesAnalyzed &&
          totalLines == other.totalLines &&
          totalTokens == other.totalTokens &&
          duplicateLines == other.duplicateLines &&
          duplicateTokens == other.duplicateTokens &&
          duplicationPercentage == other.duplicationPercentage &&
          diffDuplicationPercentage == other.diffDuplicationPercentage &&
          clusterCount == other.clusterCount &&
          cloneInstanceCount == other.cloneInstanceCount &&
          estimatedLinesSaved == other.estimatedLinesSaved &&
          clustersOutsideDiff == other.clustersOutsideDiff;

  @override
  int get hashCode => Object.hash(
    filesAnalyzed,
    totalLines,
    totalTokens,
    duplicateLines,
    duplicateTokens,
    duplicationPercentage,
    diffDuplicationPercentage,
    clusterCount,
    cloneInstanceCount,
    estimatedLinesSaved,
    clustersOutsideDiff,
  );

  @override
  String toString() =>
      'DedupeSummary($filesAnalyzed files, $clusterCount clusters, '
      '${duplicationPercentage.toStringAsFixed(1)}% duplication)';
}

/// Full analysis report produced by `pkg:dedupe`.
final class DedupeReport {
  final String version;
  final String targetPath;
  final DedupeSummary summary;
  final List<DuplicateCluster> clusters;
  final List<FileDuplicationMetric> fileMetrics;

  DedupeReport({
    required this.version,
    required this.targetPath,
    required this.summary,
    required List<DuplicateCluster> clusters,
    required List<FileDuplicationMetric> fileMetrics,
  }) : clusters = List.unmodifiable(clusters),
       fileMetrics = List.unmodifiable(fileMetrics);

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

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DedupeReport &&
          version == other.version &&
          targetPath == other.targetPath &&
          summary == other.summary &&
          _listEquals(clusters, other.clusters) &&
          _listEquals(fileMetrics, other.fileMetrics);

  @override
  int get hashCode => Object.hash(
    version,
    targetPath,
    summary,
    Object.hashAll(clusters),
    Object.hashAll(fileMetrics),
  );

  @override
  String toString() =>
      'DedupeReport(version: $version, target: $targetPath, '
      'clusters: ${clusters.length}, files: ${fileMetrics.length})';
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
  final PathFilter pathFilter;
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
  final bool useCache;
  final String? cacheDir;
  final bool clearCache;

  List<String> get excludePatterns => pathFilter.excludePatterns;
  bool get ignoreGenerated => pathFilter.ignoreGenerated;

  DedupeOptions({
    required this.targetPath,
    List<String> targets = const ['lib'],
    this.minTokens = 40,
    this.minLines = 4,
    this.ignoreComments = true,
    this.ignoreLiterals = true,
    this.ignoreIdentifiers = false,
    PathFilter? pathFilter,
    Iterable<String> excludePatterns = defaultDartExclusions,
    bool ignoreGenerated = true,
    List<String> includePatterns = const ['**/*.dart'],
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
    this.useCache = true,
    this.cacheDir,
    this.clearCache = false,
  }) : targets = List.unmodifiable(targets),
       pathFilter =
           pathFilter ??
           PathFilter(
             excludePatterns: excludePatterns,
             ignoreGenerated: ignoreGenerated,
           ),
       includePatterns = List.unmodifiable(includePatterns);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DedupeOptions &&
          targetPath == other.targetPath &&
          _listEquals(targets, other.targets) &&
          minTokens == other.minTokens &&
          minLines == other.minLines &&
          ignoreComments == other.ignoreComments &&
          ignoreLiterals == other.ignoreLiterals &&
          ignoreIdentifiers == other.ignoreIdentifiers &&
          _listEquals(excludePatterns, other.excludePatterns) &&
          _listEquals(includePatterns, other.includePatterns) &&
          gitDiffBase == other.gitDiffBase &&
          onlyChanged == other.onlyChanged &&
          failThreshold == other.failThreshold &&
          top == other.top &&
          categoryFilter == other.categoryFilter &&
          bucketFilter == other.bucketFilter &&
          format == other.format &&
          jsonOutputPath == other.jsonOutputPath &&
          sdkPath == other.sdkPath &&
          includeFileTable == other.includeFileTable &&
          includeClusters == other.includeClusters &&
          useCache == other.useCache &&
          cacheDir == other.cacheDir &&
          clearCache == other.clearCache;

  @override
  int get hashCode => Object.hash(
    targetPath,
    Object.hashAll(targets),
    minTokens,
    minLines,
    ignoreComments,
    ignoreLiterals,
    ignoreIdentifiers,
    Object.hashAll(excludePatterns),
    Object.hashAll(includePatterns),
    gitDiffBase,
    onlyChanged,
    failThreshold,
    top,
    categoryFilter,
    bucketFilter,
    format,
    jsonOutputPath,
    sdkPath,
    Object.hash(
      includeFileTable,
      includeClusters,
      useCache,
      cacheDir,
      clearCache,
    ),
  );

  @override
  String toString() =>
      'DedupeOptions(targetPath: $targetPath, format: $format, '
      'minTokens: $minTokens, minLines: $minLines)';
}

bool _listEquals<T>(List<T>? a, List<T>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
