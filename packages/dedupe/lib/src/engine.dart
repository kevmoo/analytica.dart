import 'dart:io';

import 'package:analytica/analyzer.dart';
import 'package:path/path.dart' as p;

import 'ast_extractor.dart';
import 'cache.dart';
import 'delta_service.dart';
import 'detector.dart';
import 'models.dart';
import 'tokenizer.dart';
import 'version.dart';

export 'version.dart';

/// Orchestrates file discovery, tokenization, clone detection, Git diff
/// evaluation, and metric aggregation.
class DedupeEngine {
  final DedupeOptions options;

  const DedupeEngine(this.options);

  /// Executes duplication analysis and returns a complete [DedupeReport].
  Future<DedupeReport> analyze() async {
    final targetDir = Directory(p.normalize(p.absolute(options.targetPath)));
    if (!targetDir.existsSync()) {
      throw FileSystemException(
        'Target directory does not exist',
        options.targetPath,
      );
    }

    final targetFiles = _discoverDartFiles(targetDir.path);
    if (targetFiles.isEmpty) {
      return _emptyReport();
    }

    final (sequences, candidates) = _extractFromTargetFiles(
      targetFiles,
      targetDir.path,
    );
    final detector = CloneDetector(
      minTokens: options.minTokens,
      minLines: options.minLines,
    );
    final rawClusters = detector.detect(sequences, candidates: candidates);

    final diffResult = await _evaluateGitDiff(
      rawClusters: rawClusters,
      sequences: sequences,
      targetDirPath: targetDir.path,
    );

    return _buildFinalReport(
      sequences: sequences,
      clusters: diffResult.clusters,
      clustersOutsideDiff: diffResult.clustersOutsideDiff,
      diffDuplicationPercentage: diffResult.diffDuplicationPercentage,
    );
  }

  DedupeReport _emptyReport() {
    return DedupeReport(
      version: dedupeVersion,
      targetPath: options.targetPath,
      summary: const DedupeSummary(
        filesAnalyzed: 0,
        totalLines: 0,
        totalTokens: 0,
        duplicateLines: 0,
        duplicateTokens: 0,
        duplicationPercentage: 0.0,
        clusterCount: 0,
        cloneInstanceCount: 0,
        estimatedLinesSaved: 0,
      ),
      clusters: const [],
      fileMetrics: const [],
    );
  }

  (List<TokenSequence>, List<AstCandidateUnit>) _extractFromTargetFiles(
    List<String> targetFiles,
    String targetDirPath,
  ) {
    final extractor = AstExtractor(
      ignoreComments: options.ignoreComments,
      ignoreLiterals: options.ignoreLiterals,
      ignoreIdentifiers: options.ignoreIdentifiers,
      minTokens: options.minTokens,
      minLines: options.minLines,
    );

    final cacheManager = _createCacheManager(targetDirPath);
    if (options.clearCache) {
      cacheManager.clear();
    }

    final activeRelPaths = <String>{};
    final sequences = <TokenSequence>[];
    final allCandidates = <AstCandidateUnit>[];

    for (var i = 0; i < targetFiles.length; i++) {
      final file = targetFiles[i];
      final content = File(file).readAsStringSync();
      final relPath = p.normalize(p.relative(file, from: targetDirPath));
      activeRelPaths.add(relPath);

      final contentHash = DedupeCacheManager.computeContentHash(content);
      final cached = cacheManager.getEntry(
        relPath: relPath,
        contentHash: contentHash,
        fileIndex: i,
      );

      if (cached != null) {
        sequences.add(cached.toTokenSequence(content));
        allCandidates.addAll(cached.candidates);
      } else {
        final (seq, candidates) = extractor.extract(
          filePath: relPath,
          content: content,
          fileIndex: i,
        );
        sequences.add(seq);
        allCandidates.addAll(candidates);
        cacheManager.putEntry(
          relPath: relPath,
          contentHash: contentHash,
          sequence: seq,
          candidates: candidates,
        );
      }
    }

    cacheManager.pruneStale(activeRelPaths);
    return (sequences, allCandidates);
  }

  DedupeCacheManager _createCacheManager(String targetDirPath) {
    final cacheDir = options.cacheDir ?? _resolveDefaultCacheDir(targetDirPath);
    return DedupeCacheManager(
      cacheDirPath: cacheDir,
      enabled: options.useCache,
      options: options,
    );
  }

  static String _resolveDefaultCacheDir(String targetDirPath) {
    var current = p.normalize(p.absolute(targetDirPath));
    while (true) {
      final dartTool = Directory(p.join(current, '.dart_tool'));
      if (dartTool.existsSync()) {
        return p.join(dartTool.path, 'dedupe');
      }
      final pubspec = File(p.join(current, 'pubspec.yaml'));
      if (pubspec.existsSync()) {
        return p.join(current, '.dart_tool', 'dedupe');
      }
      final parent = p.dirname(current);
      if (parent == current) break;
      current = parent;
    }
    final targetDartTool = Directory(p.join(targetDirPath, '.dart_tool'));
    if (targetDartTool.existsSync()) {
      return p.join(targetDirPath, '.dart_tool', 'dedupe');
    }
    return p.join(targetDirPath, '.dedupe_cache');
  }

  Future<
    ({
      List<DuplicateCluster> clusters,
      int clustersOutsideDiff,
      double? diffDuplicationPercentage,
    })
  >
  _evaluateGitDiff({
    required List<DuplicateCluster> rawClusters,
    required List<TokenSequence> sequences,
    required String targetDirPath,
  }) async {
    if (options.gitDiffBase == null || options.gitDiffBase!.isEmpty) {
      return (
        clusters: rawClusters,
        clustersOutsideDiff: 0,
        diffDuplicationPercentage: null,
      );
    }

    final deltaService = DedupeDeltaService(workingDirectory: targetDirPath);
    final repoRoot = await deltaService.getRepoRoot();
    final diffs = await deltaService.getParsedDiff(options.gitDiffBase!);
    final diffRanges = deltaService.extractDiffRanges(
      diffs,
      baseDir: targetDirPath,
      repoRoot: repoRoot,
    );

    final result = deltaService.applyDiffToClusters(
      clusters: rawClusters,
      sequences: sequences,
      diffRanges: diffRanges,
      onlyChanged: options.onlyChanged,
    );

    return (
      clusters: result.clusters,
      clustersOutsideDiff: result.clustersOutsideDiff,
      diffDuplicationPercentage: result.diffDuplicationPercent,
    );
  }

  DedupeReport _buildFinalReport({
    required List<TokenSequence> sequences,
    required List<DuplicateCluster> clusters,
    required int clustersOutsideDiff,
    required double? diffDuplicationPercentage,
  }) {
    final (fileDuplicateLines, fileDuplicateTokens, fileClusterCount) =
        _aggregateClusterOccurrences(clusters, sequences);

    final fileMetrics = <FileDuplicationMetric>[];
    var totalProjectLines = 0;
    var totalProjectTokens = 0;
    var totalDuplicateLines = 0;
    var totalDuplicateTokens = 0;

    for (final seq in sequences) {
      totalProjectLines += seq.totalLines;
      totalProjectTokens += seq.tokens.length;

      final dupLines = fileDuplicateLines[seq.filePath]?.length ?? 0;
      final dupTokens = fileDuplicateTokens[seq.filePath]?.length ?? 0;
      final cCount = fileClusterCount[seq.filePath] ?? 0;

      totalDuplicateLines += dupLines;
      totalDuplicateTokens += dupTokens;

      final dupPercent = seq.totalLines > 0
          ? (dupLines / seq.totalLines) * 100
          : 0.0;

      fileMetrics.add(
        FileDuplicationMetric(
          filePath: seq.filePath,
          totalLines: seq.totalLines,
          duplicateLines: dupLines,
          totalTokens: seq.tokens.length,
          duplicateTokens: dupTokens,
          duplicationPercentage: dupPercent,
          clusterCount: cCount,
        ),
      );
    }

    var totalCloneInstances = 0;
    for (final c in clusters) {
      totalCloneInstances += c.instances.length;
    }
    final totalLinesSaved = _computeTotalLinesSaved(clusters);

    final overallDuplicationPercentage = totalProjectLines > 0
        ? (totalDuplicateLines / totalProjectLines) * 100
        : 0.0;

    final summary = DedupeSummary(
      filesAnalyzed: sequences.length,
      totalLines: totalProjectLines,
      totalTokens: totalProjectTokens,
      duplicateLines: totalDuplicateLines,
      duplicateTokens: totalDuplicateTokens,
      duplicationPercentage: overallDuplicationPercentage,
      diffDuplicationPercentage: diffDuplicationPercentage,
      clusterCount: clusters.length,
      cloneInstanceCount: totalCloneInstances,
      estimatedLinesSaved: totalLinesSaved,
      clustersOutsideDiff: clustersOutsideDiff,
    );

    return DedupeReport(
      version: dedupeVersion,
      targetPath: options.targetPath,
      summary: summary,
      clusters: clusters,
      fileMetrics: fileMetrics,
    );
  }

  static int _computeTotalLinesSaved(List<DuplicateCluster> clusters) {
    if (clusters.isEmpty) return 0;

    final lineMaxInstances = <String, Map<int, int>>{};

    for (final cluster in clusters) {
      final instanceCount = cluster.instances.length;
      if (instanceCount < 2) continue;

      for (final instance in cluster.instances) {
        final fileMap = lineMaxInstances.putIfAbsent(
          instance.filePath,
          () => <int, int>{},
        );
        for (var l = instance.startLine; l <= instance.endLine; l++) {
          final currentMax = fileMap[l] ?? 0;
          if (instanceCount > currentMax) {
            fileMap[l] = instanceCount;
          }
        }
      }
    }

    var savedAccumulator = 0.0;
    for (final fileMap in lineMaxInstances.values) {
      for (final maxN in fileMap.values) {
        if (maxN >= 2) {
          savedAccumulator += (maxN - 1) / maxN;
        }
      }
    }

    return savedAccumulator.round();
  }

  static (Map<String, Set<int>>, Map<String, Set<int>>, Map<String, int>)
  _aggregateClusterOccurrences(
    List<DuplicateCluster> clusters,
    List<TokenSequence> sequences,
  ) {
    final fileDuplicateLines = <String, Set<int>>{};
    final fileDuplicateTokens = <String, Set<int>>{};
    final fileClusterCount = <String, int>{};
    final seqByPath = {for (final s in sequences) s.filePath: s};

    for (final cluster in clusters) {
      _processClusterOccurrences(
        cluster,
        seqByPath,
        fileDuplicateLines,
        fileDuplicateTokens,
        fileClusterCount,
      );
    }

    return (fileDuplicateLines, fileDuplicateTokens, fileClusterCount);
  }

  static void _processClusterOccurrences(
    DuplicateCluster cluster,
    Map<String, TokenSequence> seqByPath,
    Map<String, Set<int>> fileDuplicateLines,
    Map<String, Set<int>> fileDuplicateTokens,
    Map<String, int> fileClusterCount,
  ) {
    final touchedFilesInCluster = <String>{};

    for (final instance in cluster.instances) {
      final filePath = instance.filePath;
      touchedFilesInCluster.add(filePath);

      _recordInstanceLines(fileDuplicateLines, filePath, instance);
      final seq = seqByPath[filePath];
      if (seq != null) {
        _recordInstanceTokens(fileDuplicateTokens, filePath, instance, seq);
      }
    }

    for (final filePath in touchedFilesInCluster) {
      fileClusterCount[filePath] = (fileClusterCount[filePath] ?? 0) + 1;
    }
  }

  static void _recordInstanceLines(
    Map<String, Set<int>> fileDuplicateLines,
    String filePath,
    CloneInstance instance,
  ) {
    final lineSet = fileDuplicateLines.putIfAbsent(filePath, () => <int>{});
    for (var l = instance.startLine; l <= instance.endLine; l++) {
      lineSet.add(l);
    }
  }

  static void _recordInstanceTokens(
    Map<String, Set<int>> fileDuplicateTokens,
    String filePath,
    CloneInstance instance,
    TokenSequence seq,
  ) {
    final tokenSet = fileDuplicateTokens.putIfAbsent(filePath, () => <int>{});
    for (var t = 0; t < seq.tokens.length; t++) {
      final tok = seq.tokens[t];
      if (tok.startLine >= instance.startLine &&
          tok.endLine <= instance.endLine) {
        tokenSet.add(t);
      }
    }
  }

  List<String> _discoverDartFiles(String rootPath) {
    final targetDir = Directory(p.normalize(p.absolute(rootPath)));
    if (!targetDir.existsSync()) {
      return const [];
    }

    final excludes = options.excludePatterns.map(WildcardPattern.new).toList();
    final includes = options.includePatterns.map(WildcardPattern.new).toList();

    final discovered = <String>{};
    for (final target in options.targets) {
      _collectFromTarget(
        targetDir: targetDir,
        target: target,
        includes: includes,
        excludes: excludes,
        discovered: discovered,
      );
    }

    final result = discovered.toList()..sort();
    return result;
  }

  static void _collectFromTarget({
    required Directory targetDir,
    required String target,
    required List<WildcardPattern> includes,
    required List<WildcardPattern> excludes,
    required Set<String> discovered,
  }) {
    final fullPath = p.normalize(p.join(targetDir.path, target));
    final type = FileSystemEntity.typeSync(fullPath);

    if (type == FileSystemEntityType.file) {
      if (_matchesFilters(fullPath, targetDir.path, includes, excludes)) {
        discovered.add(fullPath);
      }
    } else if (type == FileSystemEntityType.directory) {
      _collectFromDirectory(
        dir: Directory(fullPath),
        rootDirPath: targetDir.path,
        includes: includes,
        excludes: excludes,
        discovered: discovered,
      );
    }
  }

  static void _collectFromDirectory({
    required Directory dir,
    required String rootDirPath,
    required List<WildcardPattern> includes,
    required List<WildcardPattern> excludes,
    required Set<String> discovered,
  }) {
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is File &&
          _matchesFilters(entity.path, rootDirPath, includes, excludes)) {
        discovered.add(entity.path);
      }
    }
  }

  static bool _matchesFilters(
    String filePath,
    String rootDirPath,
    List<WildcardPattern> includes,
    List<WildcardPattern> excludes,
  ) {
    if (!filePath.endsWith('.dart')) return false;

    final relPath = p.normalize(p.relative(filePath, from: rootDirPath));
    final forwardRelPath = relPath.replaceAll(r'\', '/');
    final rootedPath = '/$forwardRelPath';
    final basename = p.basename(filePath);

    for (final pattern in excludes) {
      if (pattern.matches(forwardRelPath) ||
          pattern.matches(rootedPath) ||
          pattern.matches(basename)) {
        return false;
      }
    }

    for (final pattern in includes) {
      if (pattern.matches(forwardRelPath) ||
          pattern.matches(rootedPath) ||
          pattern.matches(basename)) {
        return true;
      }
    }

    return false;
  }
}
