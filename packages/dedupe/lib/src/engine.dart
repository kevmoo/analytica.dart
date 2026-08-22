import 'dart:io';

import 'package:analytica/analyzer.dart';
import 'package:path/path.dart' as p;

import 'delta_service.dart';
import 'detector.dart';
import 'models.dart';
import 'tokenizer.dart';

const String dedupeVersion = '0.1.0-wip';

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

    final sequences = _tokenizeTargetFiles(targetFiles, targetDir.path);
    final detector = CloneDetector(
      minTokens: options.minTokens,
      minLines: options.minLines,
    );
    final rawClusters = detector.detect(sequences);

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

  List<TokenSequence> _tokenizeTargetFiles(
    List<String> targetFiles,
    String targetDirPath,
  ) {
    final tokenizer = DartTokenizer(
      ignoreComments: options.ignoreComments,
      ignoreLiterals: options.ignoreLiterals,
      ignoreIdentifiers: options.ignoreIdentifiers,
    );

    final sequences = <TokenSequence>[];
    for (final file in targetFiles) {
      final content = File(file).readAsStringSync();
      final relPath = p.relative(file, from: targetDirPath);
      sequences.add(
        tokenizer.tokenize(filePath: p.normalize(relPath), content: content),
      );
    }
    return sequences;
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
    final diffs = await deltaService.getParsedDiff(options.gitDiffBase!);
    final diffRanges = deltaService.extractDiffRanges(
      diffs,
      baseDir: targetDirPath,
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
    var totalLinesSaved = 0;
    for (final c in clusters) {
      totalCloneInstances += c.instances.length;
      totalLinesSaved += c.estimatedLinesSaved;
    }

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
    final excludePatterns = options.excludePatterns
        .map(WildcardPattern.new)
        .toList();
    final files = <String>[];

    for (final target in options.targets) {
      final resolved = p.normalize(p.join(rootPath, target));
      final type = FileSystemEntity.typeSync(resolved);
      if (type == FileSystemEntityType.directory) {
        _collectFilesFromDir(
          Directory(resolved),
          rootPath,
          excludePatterns,
          files,
        );
      } else if (type == FileSystemEntityType.file &&
          resolved.endsWith('.dart')) {
        files.add(resolved);
      }
    }

    files.sort();
    return files;
  }

  static void _collectFilesFromDir(
    Directory dir,
    String rootPath,
    List<WildcardPattern> excludePatterns,
    List<String> outFiles,
  ) {
    final rel = p.relative(dir.path, from: rootPath);
    final normalized = p.normalize(rel).replaceAll(r'\', '/');
    if (_isExcluded(normalized, p.basename(dir.path), excludePatterns)) {
      return;
    }

    for (final entity in dir.listSync(followLinks: false)) {
      if (entity is Directory) {
        _collectFilesFromDir(entity, rootPath, excludePatterns, outFiles);
      } else if (entity is File && entity.path.endsWith('.dart')) {
        final fRel = p.relative(entity.path, from: rootPath);
        final fNorm = p.normalize(fRel).replaceAll(r'\', '/');
        if (!_isExcluded(fNorm, p.basename(entity.path), excludePatterns)) {
          outFiles.add(entity.path);
        }
      }
    }
  }

  static bool _isExcluded(
    String normalized,
    String basename,
    List<WildcardPattern> excludePatterns,
  ) {
    if (normalized.startsWith('.dart_tool/') ||
        normalized.startsWith('.git/') ||
        normalized.startsWith('build/') ||
        normalized == '.dart_tool' ||
        normalized == '.git' ||
        normalized == 'build') {
      return true;
    }

    return WildcardPattern.anyMatch(excludePatterns, normalized) ||
        WildcardPattern.anyMatch(excludePatterns, basename);
  }
}
