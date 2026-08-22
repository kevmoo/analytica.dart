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

    // 1. Tokenize all discovered Dart files
    final tokenizer = DartTokenizer(
      ignoreComments: options.ignoreComments,
      ignoreLiterals: options.ignoreLiterals,
      ignoreIdentifiers: options.ignoreIdentifiers,
    );

    final sequences = <TokenSequence>[];
    for (final file in targetFiles) {
      final content = File(file).readAsStringSync();
      final relPath = p.relative(file, from: targetDir.path);
      sequences.add(
        tokenizer.tokenize(filePath: p.normalize(relPath), content: content),
      );
    }

    // 2. Execute Clone Detection
    final detector = CloneDetector(
      minTokens: options.minTokens,
      minLines: options.minLines,
    );

    var rawClusters = detector.detect(sequences);

    // 3. Apply Git Diff Evaluation if requested
    var clustersOutsideDiff = 0;
    double? diffDuplicationPercentage;

    if (options.gitDiffBase != null && options.gitDiffBase!.isNotEmpty) {
      final deltaService = DedupeDeltaService(workingDirectory: targetDir.path);
      final diffs = await deltaService.getParsedDiff(options.gitDiffBase!);
      final diffRanges = deltaService.extractDiffRanges(
        diffs,
        baseDir: targetDir.path,
      );

      final result = deltaService.applyDiffToClusters(
        clusters: rawClusters,
        sequences: sequences,
        diffRanges: diffRanges,
        onlyChanged: options.onlyChanged,
      );

      rawClusters = result.clusters;
      clustersOutsideDiff = result.clustersOutsideDiff;
      diffDuplicationPercentage = result.diffDuplicationPercent;
    }

    // 4. Compute per-file metrics
    final fileDuplicateLines = <String, Set<int>>{};
    final fileDuplicateTokens = <String, Set<int>>{};
    final fileClusterCount = <String, int>{};

    for (final cluster in rawClusters) {
      final touchedFilesInCluster = <String>{};

      for (final instance in cluster.instances) {
        final filePath = instance.filePath;
        touchedFilesInCluster.add(filePath);

        final lineSet = fileDuplicateLines.putIfAbsent(filePath, () => <int>{});
        for (var l = instance.startLine; l <= instance.endLine; l++) {
          lineSet.add(l);
        }

        final seq = sequences.firstWhere((s) => s.filePath == filePath);
        final tokenSet = fileDuplicateTokens.putIfAbsent(
          filePath,
          () => <int>{},
        );
        for (var t = 0; t < seq.tokens.length; t++) {
          final tok = seq.tokens[t];
          if (tok.startLine >= instance.startLine &&
              tok.endLine <= instance.endLine) {
            tokenSet.add(t);
          }
        }
      }

      for (final filePath in touchedFilesInCluster) {
        fileClusterCount[filePath] = (fileClusterCount[filePath] ?? 0) + 1;
      }
    }

    final fileMetrics = <FileDuplicationMetric>[];
    var totalProjectLines = 0;
    var totalProjectTokens = 0;
    var totalDuplicateLines = 0;
    var totalDuplicateTokens = 0;
    var totalCloneInstances = 0;
    var totalLinesSaved = 0;

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

    for (final c in rawClusters) {
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
      clusterCount: rawClusters.length,
      cloneInstanceCount: totalCloneInstances,
      estimatedLinesSaved: totalLinesSaved,
      clustersOutsideDiff: clustersOutsideDiff,
    );

    return DedupeReport(
      version: dedupeVersion,
      targetPath: options.targetPath,
      summary: summary,
      clusters: rawClusters,
      fileMetrics: fileMetrics,
    );
  }

  List<String> _discoverDartFiles(String rootPath) {
    final excludePatterns = options.excludePatterns
        .map(WildcardPattern.new)
        .toList();
    final files = <String>[];

    void visit(FileSystemEntity entity) {
      final rel = p.relative(entity.path, from: rootPath);
      final normalized = p.normalize(rel).replaceAll(r'\', '/');

      // Check exclusions on directories and files
      if (normalized.startsWith('.dart_tool/') ||
          normalized.startsWith('.git/') ||
          normalized.startsWith('build/') ||
          normalized == '.dart_tool' ||
          normalized == '.git' ||
          normalized == 'build') {
        return;
      }

      if (WildcardPattern.anyMatch(excludePatterns, normalized) ||
          WildcardPattern.anyMatch(excludePatterns, p.basename(entity.path))) {
        return;
      }

      if (entity is Directory) {
        for (final child in entity.listSync(followLinks: false)) {
          visit(child);
        }
      } else if (entity is File && entity.path.endsWith('.dart')) {
        files.add(entity.path);
      }
    }

    for (final target in options.targets) {
      final resolved = p.normalize(p.join(rootPath, target));
      final type = FileSystemEntity.typeSync(resolved);
      if (type == FileSystemEntityType.directory) {
        visit(Directory(resolved));
      } else if (type == FileSystemEntityType.file &&
          resolved.endsWith('.dart')) {
        visit(File(resolved));
      }
    }

    files.sort();
    return files;
  }
}
