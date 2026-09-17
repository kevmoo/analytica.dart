import 'package:pool/pool.dart';
import 'complexity_analyzer.dart';
import 'git_diff_service.dart';

/// Describes the delta trajectory of a function's cognitive complexity score
/// or file/declaration line count.
enum DeltaStatus {
  added,
  increased,
  improved,
  unchanged,
  removed;

  String get label => name.toUpperCase();
}

/// Represents the comparison between historical and current file line counts.
class FileLineDelta {
  final String filePath;
  final int? oldLines;
  final int? newLines;
  final DeltaStatus status;

  const FileLineDelta({
    required this.filePath,
    required this.oldLines,
    required this.newLines,
    required this.status,
  });

  int get delta => (newLines ?? 0) - (oldLines ?? 0);

  /// Whether this file triggers an opt-in file line violation.
  ///
  /// Strictly returns `false` when [maxFileLines] is `null` or `<= 0`.
  /// When [maxFileLines] is enabled, a file is a violation if:
  /// 1. It is newly added (`oldLines == null || oldLines == 0`) and exceeds
  ///    [maxFileLines].
  /// 2. It crossed [maxFileLines]
  ///    (`oldLines! <= maxFileLines && newLines! > maxFileLines`).
  /// 3. It was already above [maxFileLines] and grew in line count
  ///    (`newLines! > oldLines!`).
  bool isViolation({int? maxFileLines, bool failOnIncrease = false}) {
    if (maxFileLines == null || maxFileLines <= 0) return false;
    final current = newLines;
    if (current == null || current <= maxFileLines) return false;

    final previous = oldLines ?? 0;
    if (previous <= maxFileLines) return true;
    return current > previous;
  }

  Map<String, dynamic> toJson({
    int? maxFileLines,
    bool failOnIncrease = false,
  }) => {
    'file': filePath,
    'old_lines': oldLines,
    'new_lines': newLines,
    'delta': delta,
    'status': status.name,
    'violation': isViolation(
      maxFileLines: maxFileLines,
      failOnIncrease: failOnIncrease,
    ),
  };
}

/// Represents the comparison between historical and current complexity scores
/// and declaration line spans.
class ComplexityDelta {
  final String filePath;
  final String name;
  final int startLine;
  final int endLine;
  final int? oldScore;
  final int? newScore;
  final int? oldLines;
  final int? newLines;
  final DeltaStatus status;

  const ComplexityDelta({
    required this.filePath,
    required this.name,
    required this.startLine,
    required this.endLine,
    required this.oldScore,
    required this.newScore,
    required this.status,
    this.oldLines,
    this.newLines,
  });

  int get delta => (newScore ?? 0) - (oldScore ?? 0);

  int get lineDelta => (newLines ?? 0) - (oldLines ?? 0);

  bool isScoreViolation({int? failThreshold, bool failOnIncrease = false}) {
    if (failOnIncrease &&
        status == DeltaStatus.increased &&
        (failThreshold == null || (newScore ?? 0) > failThreshold)) {
      return true;
    }
    if (failThreshold != null &&
        newScore != null &&
        newScore! > failThreshold) {
      return status == DeltaStatus.added || status == DeltaStatus.increased;
    }
    return false;
  }

  bool isFunctionLineViolation({
    int? maxFunctionLines,
    bool failOnIncrease = false,
  }) {
    if (maxFunctionLines == null || maxFunctionLines <= 0) return false;
    final current = newLines;
    if (current == null || current <= maxFunctionLines) return false;

    final previous = oldLines ?? 0;
    if (previous <= maxFunctionLines) return true;
    return current > previous;
  }

  bool isViolation({
    int? failThreshold,
    int? maxFunctionLines,
    bool failOnIncrease = false,
  }) =>
      isScoreViolation(
        failThreshold: failThreshold,
        failOnIncrease: failOnIncrease,
      ) ||
      isFunctionLineViolation(
        maxFunctionLines: maxFunctionLines,
        failOnIncrease: failOnIncrease,
      );

  Map<String, dynamic> toJson({
    int? failThreshold,
    int? maxFunctionLines,
    bool failOnIncrease = false,
  }) => {
    'file': filePath,
    'name': name,
    'start_line': startLine,
    'end_line': endLine,
    'old_score': oldScore,
    'new_score': newScore,
    if (oldLines != null) 'old_lines': oldLines,
    if (newLines != null) 'new_lines': newLines,
    'delta': delta,
    'status': status.name,
    'violation': isViolation(
      failThreshold: failThreshold,
      maxFunctionLines: maxFunctionLines,
      failOnIncrease: failOnIncrease,
    ),
  };
}

/// Summarizes cognitive complexity delta metrics across a repository
/// evaluation.
class DeltaSummary {
  final String baseRef;
  final String targetRef;
  final int filesAnalyzed;
  final List<ComplexityDelta> deltas;
  final List<FileLineDelta> fileDeltas;

  const DeltaSummary({
    required this.baseRef,
    required this.targetRef,
    required this.filesAnalyzed,
    required this.deltas,
    this.fileDeltas = const [],
  });

  int get netDelta => deltas.fold(0, (sum, d) => sum + d.delta);

  int get countAdded =>
      deltas.where((d) => d.status == DeltaStatus.added).length;

  int get countIncreased =>
      deltas.where((d) => d.status == DeltaStatus.increased).length;

  int get countImproved =>
      deltas.where((d) => d.status == DeltaStatus.improved).length;

  int countFileViolations({int? maxFileLines, bool failOnIncrease = false}) =>
      fileDeltas
          .where(
            (f) => f.isViolation(
              maxFileLines: maxFileLines,
              failOnIncrease: failOnIncrease,
            ),
          )
          .length;

  int countViolations({
    int? failThreshold,
    int? maxFileLines,
    int? maxFunctionLines,
    bool failOnIncrease = false,
  }) =>
      deltas
          .where(
            (d) => d.isViolation(
              failThreshold: failThreshold,
              maxFunctionLines: maxFunctionLines,
              failOnIncrease: failOnIncrease,
            ),
          )
          .length +
      countFileViolations(
        maxFileLines: maxFileLines,
        failOnIncrease: failOnIncrease,
      );

  /// Whether this diff is quiet enough to skip a PR comment.
  ///
  /// Clean means nothing crossed [failThreshold] (or opt-in line limits) *and*
  /// no declaration got more complex. A diff that only improves complexity is
  /// clean: the numbers still land in the step summary, but they are not worth
  /// an email.
  bool isClean({
    int? failThreshold,
    int? maxFileLines,
    int? maxFunctionLines,
    bool failOnIncrease = false,
  }) =>
      countViolations(
            failThreshold: failThreshold,
            maxFileLines: maxFileLines,
            maxFunctionLines: maxFunctionLines,
            failOnIncrease: failOnIncrease,
          ) ==
          0 &&
      countIncreased == 0;

  Map<String, dynamic> toJson({
    int? failThreshold,
    int? maxFileLines,
    int? maxFunctionLines,
    bool failOnIncrease = false,
  }) {
    final changedDeltas = deltas
        .where(
          (d) =>
              d.status != DeltaStatus.unchanged ||
              d.isFunctionLineViolation(
                maxFunctionLines: maxFunctionLines,
                failOnIncrease: failOnIncrease,
              ),
        )
        .toList();
    final violatedFiles = fileDeltas
        .where(
          (f) => f.isViolation(
            maxFileLines: maxFileLines,
            failOnIncrease: failOnIncrease,
          ),
        )
        .toList();
    return {
      'base_ref': baseRef,
      'target_ref': targetRef,
      'summary': {
        'files_analyzed': filesAnalyzed,
        'declarations_changed': changedDeltas.length,
        'added': countAdded,
        'increased': countIncreased,
        'improved': countImproved,
        'net_delta': netDelta,
        'violations': countViolations(
          failThreshold: failThreshold,
          maxFileLines: maxFileLines,
          maxFunctionLines: maxFunctionLines,
          failOnIncrease: failOnIncrease,
        ),
        if (maxFileLines != null && maxFileLines > 0)
          'file_line_violations': violatedFiles.length,
      },
      'deltas': changedDeltas
          .map(
            (d) => d.toJson(
              failThreshold: failThreshold,
              maxFunctionLines: maxFunctionLines,
              failOnIncrease: failOnIncrease,
            ),
          )
          .toList(),
      if (maxFileLines != null && maxFileLines > 0)
        'file_deltas': fileDeltas
            .where((f) => f.status != DeltaStatus.unchanged)
            .map(
              (f) => f.toJson(
                maxFileLines: maxFileLines,
                failOnIncrease: failOnIncrease,
              ),
            )
            .toList(),
    };
  }
}

/// Evaluates git diffs to calculate cognitive complexity score deltas and
/// optional file/declaration line deltas.
class DeltaAnalyzer {
  final ComplexityAnalyzer _analyzer;
  final GitDiffService _gitService;
  final PathFilter pathFilter;

  DeltaAnalyzer({
    ComplexityAnalyzer? analyzer,
    GitDiffService? gitService,
    String? workingDirectory,
    PathFilter? pathFilter,
  }) : pathFilter = pathFilter ?? PathFilter.defaults,
       _analyzer =
           analyzer ??
           ComplexityAnalyzer(pathFilter: pathFilter ?? PathFilter.defaults),
       _gitService =
           gitService ?? GitDiffService(workingDirectory: workingDirectory);

  /// Computes complexity deltas between [baseRef] and current working tree.
  Future<DeltaSummary> computeDeltas(
    String baseRef, {
    List<String> targetPaths = const [],
  }) async {
    final mergeBase = await _gitService.getMergeBase(baseRef);
    final rawModFiles = await _gitService.getModifiedDartFiles(
      mergeBase,
      targetPaths: targetPaths,
    );
    final modFiles = rawModFiles
        .where((f) => !pathFilter.isExcluded(f))
        .toList();
    final allDeltas = <ComplexityDelta>[];
    final allFileDeltas = <FileLineDelta>[];

    final pool = Pool(8);
    final tasks = modFiles.map(
      (relPath) => pool.withResource(() async {
        final oldContent = await _gitService.getHistoricalFileContent(
          mergeBase,
          relPath,
        );
        final newContent = await _gitService.getCurrentFileContent(relPath);

        final declDeltas = computeDeltaForCode(
          oldContent,
          newContent,
          filePath: relPath,
        );
        final fileDelta = computeFileLineDeltaForCode(
          oldContent,
          newContent,
          filePath: relPath,
        );
        return (declDeltas: declDeltas, fileDelta: fileDelta);
      }),
    );

    final results = await Future.wait(tasks);
    for (final (:declDeltas, :fileDelta) in results) {
      allDeltas.addAll(declDeltas);
      if (fileDelta != null) {
        allFileDeltas.add(fileDelta);
      }
    }

    // Sort by delta descending (regression prioritization), then new score
    allDeltas.sort((a, b) {
      final comp = b.delta.compareTo(a.delta);
      if (comp != 0) return comp;
      return (b.newScore ?? 0).compareTo(a.newScore ?? 0);
    });

    allFileDeltas.sort((a, b) => (b.newLines ?? 0).compareTo(a.newLines ?? 0));

    return DeltaSummary(
      baseRef: baseRef,
      targetRef: 'HEAD',
      filesAnalyzed: modFiles.length,
      deltas: allDeltas,
      fileDeltas: allFileDeltas,
    );
  }

  /// Computes the [FileLineDelta] between [oldCode] and [newCode], or returns
  /// `null` if suppressed via `// cognitive_complexity:ignore_for_file`.
  FileLineDelta? computeFileLineDeltaForCode(
    String oldCode,
    String newCode, {
    String filePath = '<memory>',
  }) {
    final oldLines = _analyzer.analyzeCodeLineCount(oldCode);
    final newLines = _analyzer.analyzeCodeLineCount(newCode);
    if (newLines == null && oldLines == null) return null;

    final DeltaStatus status;
    if (oldLines == null || oldLines == 0) {
      status = (newLines == null || newLines == 0)
          ? DeltaStatus.unchanged
          : DeltaStatus.added;
    } else if (newLines == null || newLines == 0) {
      status = DeltaStatus.removed;
    } else if (newLines > oldLines) {
      status = DeltaStatus.increased;
    } else if (newLines < oldLines) {
      status = DeltaStatus.improved;
    } else {
      status = DeltaStatus.unchanged;
    }

    return FileLineDelta(
      filePath: filePath,
      oldLines: oldLines == 0 ? null : oldLines,
      newLines: newLines == 0 ? null : newLines,
      status: status,
    );
  }

  /// Calculates deltas between historical [oldCode] and current [newCode].
  List<ComplexityDelta> computeDeltaForCode(
    String oldCode,
    String newCode, {
    String filePath = '<memory>',
  }) {
    final oldResults = _analyzer.analyzeCode(oldCode, filePath: filePath);
    final newResults = _analyzer.analyzeCode(newCode, filePath: filePath);

    final oldMap = {for (final f in oldResults) f.name: f};
    final newMap = {for (final f in newResults) f.name: f};
    final allNames = {...oldMap.keys, ...newMap.keys};

    final deltas = <ComplexityDelta>[];

    for (final name in allNames) {
      final oldDecl = oldMap[name];
      final newDecl = newMap[name];

      DeltaStatus status;
      if (oldDecl == null) {
        status = DeltaStatus.added;
      } else if (newDecl == null) {
        status = DeltaStatus.removed;
      } else if (newDecl.score > oldDecl.score) {
        status = DeltaStatus.increased;
      } else if (newDecl.score < oldDecl.score) {
        status = DeltaStatus.improved;
      } else if (newDecl.lineCount != oldDecl.lineCount) {
        status = newDecl.lineCount > oldDecl.lineCount
            ? DeltaStatus.increased
            : DeltaStatus.improved;
      } else {
        status = DeltaStatus.unchanged;
      }

      // Note: If only lines changed (and score is identical), preserve
      // DeltaStatus.unchanged for complexity score unless lineCount grew!
      // Wait: if maxFunctionLines is not enabled, an unchanged score must stay
      // DeltaStatus.unchanged so existing tests and Quiet-on-Clean are 100%
      // untouched! Let's keep `status` strictly tied to `score` changes, and
      // check `oldLines`/`newLines` directly in `isFunctionLineViolation`!
      if (oldDecl != null &&
          newDecl != null &&
          newDecl.score == oldDecl.score) {
        status = DeltaStatus.unchanged;
      }

      final startLine = newDecl?.startLine ?? oldDecl?.startLine ?? 0;
      final endLine = newDecl?.endLine ?? oldDecl?.endLine ?? 0;

      deltas.add(
        ComplexityDelta(
          filePath: filePath,
          name: name,
          startLine: startLine,
          endLine: endLine,
          oldScore: oldDecl?.score,
          newScore: newDecl?.score,
          oldLines: oldDecl?.lineCount,
          newLines: newDecl?.lineCount,
          status: status,
        ),
      );
    }

    return deltas;
  }
}
