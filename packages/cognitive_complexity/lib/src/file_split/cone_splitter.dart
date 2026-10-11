import 'dart:math' as math;

import 'graph_topology.dart';
import 'models.dart';

typedef ScoredCone = ({Set<int> cone, int lines, int crossings});

/// Splits bridged dominator cones into disconnected sub-components and merges
/// sibling child cones to minimize boundary crossings.
class ConeSplitter {
  final int targetLines;
  final int minClusterLines;
  final Map<String, DeclarationUnit> declsByName;
  final List<List<String>> sccs;
  final Map<int, Set<int>> dag;
  final Set<int> extractedSccs;
  final List<int> sccLineCounts;
  final List<bool> sccAllPrivate;
  final BoundaryCrossingIndex crossingIndex;
  int _nextCandidateGroupId = 0;

  ConeSplitter({
    required this.targetLines,
    required this.minClusterLines,
    required this.declsByName,
    required this.sccs,
    required this.dag,
    required this.extractedSccs,
  }) : sccLineCounts = [
         for (final scc in sccs)
           scc.fold(0, (s, n) => s + (declsByName[n]?.lineCount ?? 0)),
       ],
       sccAllPrivate = [
         for (final scc in sccs)
           scc.every((n) => !(declsByName[n]?.isPublic ?? true)),
       ],
       crossingIndex = BoundaryCrossingIndex.build(sccs, declsByName);

  int sccLines(int idx) => sccLineCounts[idx];

  int setLines(Iterable<int> indices) =>
      indices.fold(0, (s, idx) => s + sccLineCounts[idx]);

  bool isValidDownwardClosedCut(Set<int> candidate) {
    for (final u in candidate) {
      for (final v in dag[u] ?? const <int>{}) {
        if (!candidate.contains(v) && !extractedSccs.contains(v)) {
          return false;
        }
      }
    }
    return true;
  }

  List<Set<int>>? splitBridgedCone(Set<int> cone) {
    final roots = coneRoots(cone);
    if (roots.isEmpty) return null;
    final groups = _weaklyConnectedComponentsOf(cone.difference(roots));
    final largeCount = groups.where((g) => setLines(g) >= minClusterLines);
    if (largeCount.length < 2) return null;

    for (final root in roots) {
      groups[_mostConnectedGroup(root, groups)].add(root);
    }
    _absorbUndersizedGroups(groups);
    final ordered = _topologicalGroupOrder(groups);
    if (ordered == null || ordered.length < 2) return null;

    final bundledCrossings = crossingIndex.countCrossings(cone);
    final splitCrossings = ordered.fold(
      0,
      (s, g) => s + crossingIndex.countCrossings(g),
    );
    return splitCrossings > bundledCrossings ? null : ordered;
  }

  /// Index of the group that [node] has the most outgoing edges into; ties go
  /// to the larger group.
  int _mostConnectedGroup(int node, List<Set<int>> groups) {
    final successors = dag[node] ?? const <int>{};
    var best = 0;
    var bestEdges = -1;
    for (var i = 0; i < groups.length; i++) {
      final edges = successors.where(groups[i].contains).length;
      final larger = setLines(groups[i]) > setLines(groups[best]);
      if (edges > bestEdges || (edges == bestEdges && larger)) {
        best = i;
        bestEdges = edges;
      }
    }
    return best;
  }

  /// Merges every group below `minClusterLines` into the group whose members
  /// have the most edges into it, so helpers travel with their callers.
  void _absorbUndersizedGroups(List<Set<int>> groups) {
    var changed = true;
    while (changed) {
      changed = false;
      for (var i = 0; i < groups.length; i++) {
        if (setLines(groups[i]) >= minClusterLines) continue;
        final target = _mostDependentGroup(i, groups);
        if (target == null) continue;
        groups[target].addAll(groups.removeAt(i));
        changed = true;
        break;
      }
    }
  }

  int? _mostDependentGroup(int small, List<Set<int>> groups) {
    int? best;
    var bestEdges = 0;
    for (var i = 0; i < groups.length; i++) {
      if (i == small) continue;
      final edges = groups[i]
          .expand((u) => dag[u] ?? const <int>{})
          .where(groups[small].contains)
          .length;
      if (edges > bestEdges) {
        best = i;
        bestEdges = edges;
      }
    }
    return best;
  }

  /// Orders [groups] so every group is committed after the groups it depends
  /// on; independent groups follow source order. Returns `null` when the
  /// group graph is cyclic.
  List<Set<int>>? _topologicalGroupOrder(List<Set<int>> groups) {
    final pending = [...groups];
    final ordered = <Set<int>>[];
    while (pending.isNotEmpty) {
      final ready = [
        for (final g in pending)
          if (!dependsOnAnyOf(g, pending.where((o) => !identical(o, g)))) g,
      ];
      if (ready.isEmpty) return null;
      ready.sort((a, b) => _minStartLine(a).compareTo(_minStartLine(b)));
      pending.remove(ready.first);
      ordered.add(ready.first);
    }
    return ordered;
  }

  int _minStartLine(Set<int> sccIndices) => sccIndices
      .expand((i) => sccs[i])
      .map((n) => declsByName[n]?.startLine ?? 0)
      .fold(1 << 30, math.min);

  bool dependsOnAnyOf(Set<int> group, Iterable<Set<int>> others) => group
      .expand((u) => dag[u] ?? const <int>{})
      .any((v) => others.any((o) => o.contains(v)));

  /// SCCs in [cone] with no predecessor inside [cone].
  Set<int> coneRoots(Set<int> cone) {
    final hasPredecessor = <int>{
      for (final u in cone)
        for (final v in dag[u] ?? const <int>{})
          if (cone.contains(v)) v,
    };
    return cone.difference(hasPredecessor);
  }

  List<Set<int>> _weaklyConnectedComponentsOf(Set<int> nodes) {
    final index = nodes.toList();
    final position = {for (var i = 0; i < index.length; i++) index[i]: i};
    final relabeled = <int, Set<int>>{
      for (final u in nodes)
        position[u]!: {
          for (final v in dag[u] ?? const <int>{})
            if (nodes.contains(v)) position[v]!,
        },
    };
    return [
      for (final comp in computeWeaklyConnectedIslands(index.length, relabeled))
        {for (final i in comp) index[i]},
    ];
  }

  Set<int> unextractedDownwardClosure(Iterable<int> seeds) {
    final closure = <int>{
      for (final s in seeds)
        if (!extractedSccs.contains(s)) s,
    };
    final queue = closure.toList();
    while (queue.isNotEmpty) {
      final curr = queue.removeLast();
      final nextNodes = (dag[curr] ?? const <int>{}).where(
        (n) => !extractedSccs.contains(n) && closure.add(n),
      );
      queue.addAll(nextNodes);
    }
    return closure;
  }

  List<Set<int>> mergeChildConesToMinimizeCrossings(
    List<int> survivingChildren,
    Map<int, Set<int>> coneNodes,
  ) {
    final groups = _initialDownwardClosedChildGroups(
      survivingChildren,
      coneNodes,
    );
    final rejectedPhase1 = <(int, int)>{};
    while (_tryMergeOneCrossingPair(
      groups,
      rejectedPhase1,
      requireReduction: true,
    )) {}
    final rejectedPhase2 = <(int, int)>{};
    while (_tryMergeOneCrossingPair(
      groups,
      rejectedPhase2,
      requireReduction: false,
    )) {}
    return [for (final g in groups) g.sccs];
  }

  List<_CandidateGroup> _initialDownwardClosedChildGroups(
    List<int> survivingChildren,
    Map<int, Set<int>> coneNodes,
  ) {
    final closures = <int, Set<int>>{
      for (final c in survivingChildren)
        c: unextractedDownwardClosure(coneNodes[c]!),
    };
    return [
      for (final c in survivingChildren)
        if (closures[c]!.isNotEmpty &&
            !(_isAllPrivateGroup(closures[c]!) &&
                closures.entries.any((e) => e.key != c && e.value.contains(c))))
          _CandidateGroup(
            id: _nextCandidateGroupId++,
            sccs: closures[c]!,
            lines: setLines(closures[c]!),
            crossings: crossingIndex.countCrossings(closures[c]!),
            isAllPrivate: _isAllPrivateGroup(closures[c]!),
            touchedItems: {
              for (final u in closures[c]!) ...crossingIndex.itemsByScc[u],
            },
          ),
    ];
  }

  bool _isAllPrivateGroup(Set<int> group) =>
      group.every((idx) => sccAllPrivate[idx]);

  bool _tryMergeOneCrossingPair(
    List<_CandidateGroup> groups,
    Set<(int, int)> rejected, {
    required bool requireReduction,
  }) {
    for (var i = 0; i < groups.length; i++) {
      final gi = groups[i];
      if (requireReduction && gi.touchedItems.isEmpty) continue;
      for (var j = i + 1; j < groups.length; j++) {
        final pairKey = (gi.id, groups[j].id);
        if (rejected.contains(pairKey)) continue;
        if (_mergePairIfEligible(
          groups,
          i,
          j,
          requireReduction: requireReduction,
        )) {
          return true;
        }
        rejected.add(pairKey);
      }
    }
    return false;
  }

  bool _mergePairIfEligible(
    List<_CandidateGroup> groups,
    int i,
    int j, {
    required bool requireReduction,
  }) {
    final gi = groups[i];
    final gj = groups[j];
    if (!gi.canAttemptMergeWith(
      gj,
      targetLines,
      requireReduction: requireReduction,
    )) {
      return false;
    }
    final candidate = <int>{...gi.sccs, ...gj.sccs};
    final candLines = setLines(candidate);
    final bothPrivate = gi.isAllPrivate && gj.isAllPrivate;
    final maxLines = (!requireReduction && !bothPrivate)
        ? targetLines ~/ 2
        : targetLines;
    if (candLines > maxLines || !isValidDownwardClosedCut(candidate)) {
      return false;
    }
    final crossBefore = gi.crossings + gj.crossings;
    final crossAfter = crossingIndex.countCrossings(candidate);
    final worse = requireReduction
        ? crossAfter >= crossBefore
        : crossAfter > crossBefore || (!bothPrivate && crossAfter != 0);
    if (worse) return false;

    groups
      ..removeAt(j)
      ..removeAt(i)
      ..add(
        _CandidateGroup(
          id: _nextCandidateGroupId++,
          sccs: candidate,
          lines: candLines,
          crossings: crossAfter,
          isAllPrivate: bothPrivate,
          touchedItems: {...gi.touchedItems, ...gj.touchedItems},
        ),
      );
    return true;
  }
}

class _CandidateGroup {
  final int id;
  final Set<int> sccs;
  final int lines;
  final int crossings;
  final bool isAllPrivate;
  final Set<int> touchedItems;

  const _CandidateGroup({
    required this.id,
    required this.sccs,
    required this.lines,
    required this.crossings,
    required this.isAllPrivate,
    required this.touchedItems,
  });

  bool canAttemptMergeWith(
    _CandidateGroup other,
    int targetLines, {
    required bool requireReduction,
  }) {
    if (lines > targetLines || other.lines > targetLines) return false;
    if (requireReduction) {
      return touchedItems.any(other.touchedItems.contains);
    }
    if (isAllPrivate && other.isAllPrivate) return true;
    final halfTarget = targetLines ~/ 2;
    return targetLines >= 200 &&
        crossings == 0 &&
        other.crossings == 0 &&
        lines <= halfTarget &&
        other.lines <= halfTarget;
  }
}

/// Pre-indexes cross-SCC spans of private top-level declarations and private
/// members so boundary crossings for any candidate SCC set can be counted in
/// `O(touched items)` without scanning outside declarations.
class BoundaryCrossingIndex {
  final List<int> spanSizes;
  final List<List<int>> itemsByScc;
  final List<int> _hits;
  final List<int> _touched = [];

  BoundaryCrossingIndex._(this.spanSizes, this.itemsByScc)
    : _hits = List<int>.filled(spanSizes.length, 0);

  factory BoundaryCrossingIndex.build(
    List<List<String>> sccs,
    Map<String, DeclarationUnit> declsByName,
  ) {
    final nameToScc = <String, int>{
      for (var i = 0; i < sccs.length; i++)
        for (final name in sccs[i]) name: i,
    };
    final spans = <String, Set<int>>{};
    for (final decl in declsByName.values) {
      final sccIdx = nameToScc[decl.name];
      if (sccIdx == null) continue;
      if (!decl.isPublic) {
        spans.putIfAbsent(decl.name, () => <int>{}).add(sccIdx);
      }
      _recordDeclSpans(decl, sccIdx, nameToScc, spans);
    }

    final spanSizes = <int>[];
    final itemsByScc = <List<int>>[for (var i = 0; i < sccs.length; i++) []];
    for (final span in spans.values) {
      if (span.length < 2) continue;
      final itemId = spanSizes.length;
      spanSizes.add(span.length);
      for (final sccIdx in span) {
        itemsByScc[sccIdx].add(itemId);
      }
    }
    return BoundaryCrossingIndex._(spanSizes, itemsByScc);
  }

  static void _recordDeclSpans(
    DeclarationUnit decl,
    int sccIdx,
    Map<String, int> nameToScc,
    Map<String, Set<int>> spans,
  ) {
    for (final ref in decl.outgoingIntraFileRefs) {
      final targetScc = ref.startsWith('_') ? nameToScc[ref] : null;
      if (targetScc != null) {
        spans.putIfAbsent(ref, () => <int>{targetScc}).add(sccIdx);
      }
    }
    for (final entry in decl.privateMemberAccessesByTarget.entries) {
      final targetScc = nameToScc[entry.key];
      if (targetScc == null) continue;
      for (final member in entry.value) {
        spans
            .putIfAbsent('${entry.key}.$member', () => <int>{targetScc})
            .add(sccIdx);
      }
    }
  }

  int countCrossings(Set<int> sccIndices) {
    for (final sccIdx in sccIndices) {
      for (final itemId in itemsByScc[sccIdx]) {
        final prev = _hits[itemId];
        if (prev == 0) _touched.add(itemId);
        _hits[itemId] = prev + 1;
      }
    }
    var crossings = 0;
    for (final itemId in _touched) {
      if (_hits[itemId] < spanSizes[itemId]) crossings++;
      _hits[itemId] = 0;
    }
    _touched.clear();
    return crossings;
  }
}
