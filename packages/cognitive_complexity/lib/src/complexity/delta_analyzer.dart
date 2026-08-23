import 'package:glob/glob.dart';
import 'package:pool/pool.dart';
import 'complexity_analyzer.dart';
import 'git_diff_service.dart';

/// Describes the delta trajectory of a function's cognitive complexity score.
enum DeltaStatus {
  added,
  increased,
  improved,
  unchanged,
  removed;

  String get label => name.toUpperCase();
}

/// Represents the comparison between historical and current complexity scores.
class ComplexityDelta {
  final String filePath;
  final String name;
  final int startLine;
  final int endLine;
  final int? oldScore;
  final int? newScore;
  final DeltaStatus status;

  const ComplexityDelta({
    required this.filePath,
    required this.name,
    required this.startLine,
    required this.endLine,
    required this.oldScore,
    required this.newScore,
    required this.status,
  });

  int get delta => (newScore ?? 0) - (oldScore ?? 0);

  bool isViolation({int? failThreshold, bool failOnIncrease = false}) {
    // Newly added declarations have no baseline to "increase" from; they are
    // governed by [failThreshold] alone.
    //
    // When both flags are supplied, [failThreshold] gates [failOnIncrease]:
    // an increase that stays within the threshold budget is reported but is
    // not a violation. Without a threshold, any increase is a violation
    // (strict ratchet).
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

  Map<String, dynamic> toJson({
    int? failThreshold,
    bool failOnIncrease = false,
  }) => {
    'file': filePath,
    'name': name,
    'start_line': startLine,
    'end_line': endLine,
    'old_score': oldScore,
    'new_score': newScore,
    'delta': delta,
    'status': status.name,
    'violation': isViolation(
      failThreshold: failThreshold,
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

  const DeltaSummary({
    required this.baseRef,
    required this.targetRef,
    required this.filesAnalyzed,
    required this.deltas,
  });

  int get netDelta => deltas.fold(0, (sum, d) => sum + d.delta);

  int get countAdded =>
      deltas.where((d) => d.status == DeltaStatus.added).length;

  int get countIncreased =>
      deltas.where((d) => d.status == DeltaStatus.increased).length;

  int get countImproved =>
      deltas.where((d) => d.status == DeltaStatus.improved).length;

  int countViolations({int? failThreshold, bool failOnIncrease = false}) =>
      deltas
          .where(
            (d) => d.isViolation(
              failThreshold: failThreshold,
              failOnIncrease: failOnIncrease,
            ),
          )
          .length;

  Map<String, dynamic> toJson({
    int? failThreshold,
    bool failOnIncrease = false,
  }) {
    final changedDeltas = deltas
        .where((d) => d.status != DeltaStatus.unchanged)
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
          failOnIncrease: failOnIncrease,
        ),
      },
      'deltas': changedDeltas
          .map(
            (d) => d.toJson(
              failThreshold: failThreshold,
              failOnIncrease: failOnIncrease,
            ),
          )
          .toList(),
    };
  }
}

/// Compiles [patterns] into globs, ignoring blank entries.
///
/// Blank entries are dropped rather than rejected: they are what a trailing
/// comma or an empty CI variable produces, and `Glob('')` throws. A genuinely
/// malformed pattern still throws, but as a [FormatException] naming the
/// pattern rather than a scanner error pointing at an offset.
List<Glob> compileExcludeGlobs(Iterable<String> patterns) {
  final globs = <Glob>[];
  for (final raw in patterns) {
    final pattern = raw.trim();
    if (pattern.isEmpty) continue;
    try {
      globs.add(Glob(pattern));
    } on FormatException catch (e) {
      throw FormatException('Invalid exclude pattern "$pattern": ${e.message}');
    }
  }
  return globs;
}

/// Evaluates git diffs to calculate cognitive complexity score deltas.
class DeltaAnalyzer {
  final ComplexityAnalyzer _analyzer = ComplexityAnalyzer();
  final GitDiffService _gitService;

  DeltaAnalyzer({GitDiffService? gitService, String? workingDirectory})
    : _gitService =
          gitService ?? GitDiffService(workingDirectory: workingDirectory);

  /// Computes complexity deltas between [baseRef] and current working tree.
  ///
  /// Paths matching any glob in [excludeGlobs] are skipped. Generated sources
  /// are the motivating case: they routinely exceed any sensible threshold and
  /// cannot be simplified by hand, so reporting them is noise.
  Future<DeltaSummary> computeDeltas(
    String baseRef, {
    List<String> targetPaths = const [],
    List<String> excludeGlobs = const [],
  }) async {
    final mergeBase = await _gitService.getMergeBase(baseRef);
    var modFiles = await _gitService.getModifiedDartFiles(
      mergeBase,
      targetPaths: targetPaths,
    );

    final globs = compileExcludeGlobs(excludeGlobs);
    if (globs.isNotEmpty) {
      modFiles = modFiles
          .where((f) => !globs.any((g) => g.matches(f)))
          .toList();
    }
    final allDeltas = <ComplexityDelta>[];

    final pool = Pool(8);
    final tasks = modFiles.map(
      (relPath) => pool.withResource(() async {
        final oldContent = await _gitService.getHistoricalFileContent(
          mergeBase,
          relPath,
        );
        final newContent = await _gitService.getCurrentFileContent(relPath);

        return computeDeltaForCode(oldContent, newContent, filePath: relPath);
      }),
    );

    final results = await Future.wait(tasks);
    for (final fileDeltas in results) {
      allDeltas.addAll(fileDeltas);
    }

    // Sort by delta descending (regression prioritization), then new score
    allDeltas.sort((a, b) {
      final comp = b.delta.compareTo(a.delta);
      if (comp != 0) return comp;
      return (b.newScore ?? 0).compareTo(a.newScore ?? 0);
    });

    return DeltaSummary(
      baseRef: baseRef,
      targetRef: 'HEAD',
      filesAnalyzed: modFiles.length,
      deltas: allDeltas,
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
      } else {
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
          status: status,
        ),
      );
    }

    return deltas;
  }
}
