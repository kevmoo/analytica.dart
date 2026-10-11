import 'ast_collector.dart';
import 'models.dart';

/// File discovery metadata for a single Dart source file during a `shallow`
/// scan.
class ScanFileEntry {
  final String absPath;
  final String displayPath;
  final String normalizedPath;
  final bool isTestFile;
  final bool isPublicEntryFile;
  final bool isInRequestedTargets;

  const ScanFileEntry({
    required this.absPath,
    required this.displayPath,
    required this.normalizedPath,
    required this.isTestFile,
    required this.isPublicEntryFile,
    required this.isInRequestedTargets,
  });
}

/// Pre-simulation candidate single-caller helper with its static call-site and
/// parameter-clump facts.
class RawCandidate {
  final ShallowDeclNode decl;
  final ShallowDeclNode caller;
  final ShallowCallSite call;
  final int baseDeltaScore;
  final int estimatedLinesSaved;
  final List<String> reasons;
  final String? sharedParamSignatureWith;
  final int sharedParamCount;
  final String? paramsSubsetOfExistingType;
  final List<String> siblingSteps;

  const RawCandidate({
    required this.decl,
    required this.caller,
    required this.call,
    required this.baseDeltaScore,
    required this.estimatedLinesSaved,
    required this.reasons,
    required this.sharedParamSignatureWith,
    required this.sharedParamCount,
    required this.paramsSubsetOfExistingType,
    required this.siblingSteps,
  });
}

/// Builds the report ordering: classification, then caller groups ranked by
/// their most significant finding, then the caller, then simulation order.
/// Within one caller the printed order therefore matches the order in which
/// siblings were absorbed, so a `Caller CC: N (base B)` line never precedes
/// the sibling that produced `N`.
Comparator<ShallowFinding> buildFindingComparator(
  List<ShallowFinding> findings,
) {
  final groupRank = <String, int>{};
  for (final f in findings) {
    final key = _callerKey(f);
    final rank = _significanceRank(f);
    final existing = groupRank[key];
    if (existing == null || rank < existing) groupRank[key] = rank;
  }
  return (a, b) {
    final classCmp = _classificationOrder(a).compareTo(_classificationOrder(b));
    if (classCmp != 0) return classCmp;
    final aKey = _callerKey(a);
    final bKey = _callerKey(b);
    final rankCmp = groupRank[aKey]!.compareTo(groupRank[bKey]!);
    if (rankCmp != 0) return rankCmp;
    final keyCmp = aKey.compareTo(bKey);
    if (keyCmp != 0) return keyCmp;
    return a.simulationIndex.compareTo(b.simulationIndex);
  };
}

String _callerKey(ShallowFinding f) => '${f.callerFilePath}#${f.callerName}';

/// `0` for arity/signature findings, `1` for findings that move the caller's
/// score, `2` for `+0` micro-predicates.
int _significanceRank(ShallowFinding f) {
  if (f.reasons.any(
    (r) => r.startsWith('HIGH_ARITY') || r.startsWith('SIG_HEAVY'),
  )) {
    return 0;
  }
  return f.inlinedDeltaScore != 0 ? 1 : 2;
}

/// Report order of [f]'s classification: its position in
/// [ShallowClassification.values] (safest first).
int _classificationOrder(ShallowFinding f) =>
    ShallowClassification.values.indexOf(f.classification);

/// Prioritizes structural helpers (`estimatedLinesSaved > 6`), then smaller
/// caller complexity delta, then larger line savings, then source location.
int compareRawCandidates(RawCandidate a, RawCandidate b) {
  final aStructural = a.estimatedLinesSaved > 6;
  final bStructural = b.estimatedLinesSaved > 6;
  if (aStructural != bStructural) return aStructural ? -1 : 1;
  final deltaCmp = a.baseDeltaScore.compareTo(b.baseDeltaScore);
  if (deltaCmp != 0) return deltaCmp;
  final savedCmp = b.estimatedLinesSaved.compareTo(a.estimatedLinesSaved);
  if (savedCmp != 0) return savedCmp;
  final fileCmp = a.decl.filePath.compareTo(b.decl.filePath);
  if (fileCmp != 0) return fileCmp;
  return a.decl.startLine.compareTo(b.decl.startLine);
}

/// Orders [candidates] bottom-up so leaf helpers are simulated before their
/// callers when a candidate's caller is itself a candidate.
List<RawCandidate> orderBottomUp(List<RawCandidate> candidates) {
  final ordered = <RawCandidate>[];
  final visited = <RawCandidate>{};
  for (final c in candidates) {
    _visitBottomUp(c, candidates, visited, ordered);
  }
  return ordered;
}

void _visitBottomUp(
  RawCandidate current,
  List<RawCandidate> candidates,
  Set<RawCandidate> visited,
  List<RawCandidate> ordered,
) {
  if (!visited.add(current)) return;
  for (final child in candidates) {
    if (identical(child.caller, current.decl)) {
      _visitBottomUp(child, candidates, visited, ordered);
    }
  }
  ordered.add(current);
}
