import 'dart:io';
import 'dart:math' as math;

import 'package:analytica/analyzer.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:path/path.dart' as p;

import 'ast_declaration_harvester.dart';
import 'graph_topology.dart';
import 'models.dart';

/// Analyzes a Dart source file's resolved AST to build its intra-file
/// declaration dependency graph, condense Strongly Connected Components (SCCs),
/// absorb single-dominator private helpers, and recommend low-churn acyclic
/// extraction cuts (`Tier 1`, `Tier 2`, or `Tier 3`).
class FileSplitAnalyzer {
  final String? sdkPath;

  const FileSplitAnalyzer({this.sdkPath});

  /// Resolves and analyzes [filePath] to produce a [FileSplitReport].
  Future<FileSplitReport> analyzeFile(
    String filePath, {
    int targetLines = 800,
    int minClusterLines = 40,
    bool? useParts,
  }) async {
    final reports = await analyzeFiles(
      [filePath],
      targetLines: targetLines,
      minClusterLines: minClusterLines,
      useParts: useParts,
    );
    return reports.single;
  }

  /// Resolves and analyzes multiple [filePaths] in a single shared
  /// [AnalysisContextHelper] to amortize analyzer initialization.
  Future<List<FileSplitReport>> analyzeFiles(
    List<String> filePaths, {
    int targetLines = 800,
    int minClusterLines = 40,
    bool? useParts,
  }) async {
    if (filePaths.isEmpty) return const [];
    final absPaths = [
      for (final path in filePaths) p.canonicalize(File(path).absolute.path),
    ];
    for (var i = 0; i < filePaths.length; i++) {
      if (!File(absPaths[i]).existsSync()) {
        throw FileSystemException('Target file does not exist', filePaths[i]);
      }
    }
    final helper = AnalysisContextHelper(
      includedPaths: absPaths,
      sdkPath: sdkPath,
    );
    final reports = <FileSplitReport>[];
    for (var i = 0; i < filePaths.length; i++) {
      final unitResult = await helper.getRequiredResolvedUnit(absPaths[i]);
      reports.add(
        analyzeResolvedUnit(
          unitResult,
          displayPath: filePaths[i],
          targetLines: targetLines,
          minClusterLines: minClusterLines,
          useParts: useParts,
        ),
      );
    }
    return List.unmodifiable(reports);
  }
}

/// Analyzes an already-resolved [unitResult].
FileSplitReport analyzeResolvedUnit(
  ResolvedUnitResult unitResult, {
  String? displayPath,
  int targetLines = 800,
  int minClusterLines = 40,
  bool? useParts,
}) {
  final pathStr = displayPath ?? unitResult.path;
  final totalLines = unitResult.lineInfo.lineCount;
  final populated = harvestDeclarationUnits(
    unitResult.unit,
    unitResult.lineInfo,
  );

  if (populated.length <= 1 && useParts != true) {
    return FileSplitReport(
      filePath: pathStr,
      totalLines: totalLines,
      declarationCount: populated.length,
      lcom4Islands: populated.isEmpty ? 0 : 1,
      sccCount: populated.length,
      maxTopologicalDepth: 0,
      clusters: const [],
      survivingDeclarations: List.unmodifiable(populated.values),
      targetLines: targetLines,
      useParts: useParts,
    );
  }

  final pinnedGroups = fuseHardPinnedPeers(populated);
  final sccs = computeTarjanSccs(pinnedGroups, populated);
  final sccDag = buildCondensationDag(sccs, populated);
  final depths = computeTopologicalDepths(sccs.length, sccDag);
  final maxDepth = depths.values.fold(0, math.max);
  final islands = computeWeaklyConnectedIslands(sccs.length, sccDag);

  final planner = _ExtractionCutPlanner(
    filePath: pathStr,
    totalLines: totalLines,
    targetLines: targetLines,
    minClusterLines: minClusterLines,
    useParts: useParts,
    declsByName: populated,
    sccs: sccs,
    dag: sccDag,
    depths: depths,
    islands: islands,
  );
  final (:clusters, :surviving, :hasSurvivingCoupledScc) = planner.plan();

  return FileSplitReport(
    filePath: pathStr,
    totalLines: totalLines,
    declarationCount: populated.length,
    lcom4Islands: islands.length,
    sccCount: sccs.length,
    maxTopologicalDepth: maxDepth,
    clusters: List.unmodifiable(clusters),
    survivingDeclarations: List.unmodifiable(surviving),
    hasSurvivingCoupledScc: hasSurvivingCoupledScc,
    targetLines: targetLines,
    useParts: useParts,
  );
}

typedef _ScoredCone = ({Set<int> cone, int lines, int crossings});

class _ExtractionCutPlanner {
  final String filePath;

  /// Physical line count of the file, including imports, comments, and blank
  /// lines that are not attributed to any declaration.
  final int totalLines;
  final int targetLines;
  final int minClusterLines;
  final bool? useParts;
  final Map<String, DeclarationUnit> declsByName;
  final List<List<String>> sccs;
  final Map<int, Set<int>> dag;
  final Map<int, int> depths;
  final List<Set<int>> islands;

  final String stem;
  final extractedSccs = <int>{};
  final clusters = <SplitCluster>[];
  final Set<String> usedFileNames;
  final List<int> _sccLineCounts;
  final List<bool> _sccAllPrivate;
  final _BoundaryCrossingIndex _crossingIndex;
  int _nextCandidateGroupId = 0;

  _ExtractionCutPlanner({
    required this.filePath,
    required this.totalLines,
    required this.targetLines,
    required this.minClusterLines,
    required this.useParts,
    required this.declsByName,
    required this.sccs,
    required this.dag,
    required this.depths,
    required this.islands,
  }) : stem = p.basenameWithoutExtension(filePath),
       usedFileNames = <String>{p.basename(filePath)},
       _sccLineCounts = [
         for (final scc in sccs)
           scc.fold(0, (s, n) => s + (declsByName[n]?.lineCount ?? 0)),
       ],
       _sccAllPrivate = [
         for (final scc in sccs)
           scc.every((n) => !(declsByName[n]?.isPublic ?? true)),
       ],
       _crossingIndex = _BoundaryCrossingIndex.build(sccs, declsByName);

  int _sccLines(int idx) => _sccLineCounts[idx];

  int _setLines(Iterable<int> indices) =>
      indices.fold(0, (s, idx) => s + _sccLineCounts[idx]);

  ({
    List<SplitCluster> clusters,
    List<DeclarationUnit> surviving,
    bool hasSurvivingCoupledScc,
  })
  plan() {
    _extractDisjointIslands();
    _extractDominatorCones();
    _extractOversizedSccFallbacks();
    _reabsorbSurplusSmallCuts();

    final remLines = _remainingLines();
    final hasSurvivingCoupledScc =
        [
          for (var i = 0; i < sccs.length; i++)
            if (!extractedSccs.contains(i) && sccs[i].length > 1) i,
        ].any(
          (i) =>
              _sccLines(i) > targetLines ||
              remLines - _sccLines(i) <= targetLines,
        );

    final surviving = <DeclarationUnit>[
      for (var i = 0; i < sccs.length; i++)
        if (!extractedSccs.contains(i))
          for (final name in sccs[i]) ?declsByName[name],
    ]..sort((a, b) => a.startLine.compareTo(b.startLine));

    return (
      clusters: clusters,
      surviving: surviving,
      hasSurvivingCoupledScc: hasSurvivingCoupledScc,
    );
  }

  void _extractDisjointIslands() {
    if (islands.length <= 1) return;
    final sortedIslands = [...islands]
      ..sort((a, b) => _setLines(b).compareTo(_setLines(a)));

    for (final island in sortedIslands.skip(1)) {
      if (_remainingLines() <= targetLines) break;
      if (_setLines(island) >= minClusterLines) {
        _commitCluster(island, isDisjointIsland: true);
      }
    }
  }

  void _extractDominatorCones() {
    final idom = computeImmediateDominators(sccs.length, dag);
    final domTree = _buildDomTree(idom);
    final coneSizes = <int, int>{};
    final coneNodes = <int, Set<int>>{};
    final roots = <int>[];

    for (var i = 0; i < sccs.length; i++) {
      if (!idom.containsKey(i)) {
        roots.add(i);
        _extractNodeCone(i, idom, domTree, coneSizes, coneNodes);
      }
    }

    _commitRemainingRootCones(roots, coneNodes);
  }

  void _commitRemainingRootCones(
    List<int> roots,
    Map<int, Set<int>> coneNodes,
  ) {
    final survivingRoots = [
      for (final r in roots)
        if (!extractedSccs.contains(r) && coneNodes.containsKey(r)) r,
    ];
    if (survivingRoots.isEmpty || _remainingLines() <= targetLines) return;

    final mergedGroups = _mergeChildConesToMinimizeCrossings(
      survivingRoots,
      coneNodes,
    );
    while (_remainingLines() > targetLines) {
      if (!_extractNextEligibleGroup(
        mergedGroups,
        _remainingLines,
        requireSmallerThanRemaining: true,
      )) {
        break;
      }
    }
  }

  Map<int, List<int>> _buildDomTree(Map<int, int> idom) {
    final domTree = <int, List<int>>{
      for (var i = 0; i < sccs.length; i++) i: [],
    };
    for (final entry in idom.entries) {
      domTree[entry.value]!.add(entry.key);
    }
    return domTree;
  }

  void _extractNodeCone(
    int node,
    Map<int, int> idom,
    Map<int, List<int>> domTree,
    Map<int, int> coneSizes,
    Map<int, Set<int>> coneNodes,
  ) {
    for (final child in domTree[node]!) {
      _extractNodeCone(child, idom, domTree, coneSizes, coneNodes);
    }
    if (extractedSccs.contains(node)) return;

    final survivingChildren = [
      for (final child in domTree[node]!)
        if (!extractedSccs.contains(child)) child,
    ];
    final mergedAll = <int>{
      node,
      for (final c in survivingChildren) ...coneNodes[c]!,
    };
    final totalConeLines = _setLines(mergedAll);

    if (totalConeLines <= targetLines && _isValidDownwardClosedCut(mergedAll)) {
      coneSizes[node] = totalConeLines;
      coneNodes[node] = mergedAll;
    } else {
      final currentNodes = _pruneOversizedNodeChildren(
        node,
        survivingChildren,
        coneNodes,
      );
      coneSizes[node] = _setLines(currentNodes);
      coneNodes[node] = currentNodes;
    }
  }

  Set<int> _pruneOversizedNodeChildren(
    int node,
    List<int> survivingChildren,
    Map<int, Set<int>> coneNodes,
  ) {
    final groups = _mergeChildConesToMinimizeCrossings(
      survivingChildren,
      coneNodes,
    );
    final allNodeSccs = <int>{
      node,
      for (final c in survivingChildren) ...coneNodes[c]!,
    };

    while (_setLines(allNodeSccs.difference(extractedSccs)) > targetLines) {
      if (!_extractNextEligibleGroup(
        groups,
        () => _setLines(allNodeSccs.difference(extractedSccs)),
        requireSmallerThanRemaining: false,
      )) {
        break;
      }
    }
    return allNodeSccs.difference(extractedSccs);
  }

  bool _extractNextEligibleGroup(
    List<Set<int>> groups,
    int Function() currentRemainingLines, {
    required bool requireSmallerThanRemaining,
  }) {
    final remLines = currentRemainingLines();
    if (remLines <= targetLines) return false;

    final neededLines = remLines - targetLines;
    final remSccCount = sccs.length - extractedSccs.length;
    final eligible = <_ScoredCone>[];
    for (final g in groups) {
      final unextracted = _unextractedDownwardClosure(g);
      final lines = _setLines(unextracted);
      final withinRem =
          !requireSmallerThanRemaining ||
          (lines < remLines &&
              (unextracted.length < remSccCount ||
                  _splitBridgedCone(unextracted) != null));
      if (lines >= minClusterLines &&
          lines <= targetLines &&
          withinRem &&
          _isValidDownwardClosedCut(unextracted)) {
        eligible.add((
          cone: unextracted,
          lines: lines,
          crossings: _crossingIndex.countCrossings(unextracted),
        ));
      }
    }
    if (eligible.isEmpty) return false;
    eligible.sort((a, b) => _compareCandidateCones(a, b, neededLines));
    _commitCone(eligible.first.cone);
    return true;
  }

  /// Commits [cone] as one cluster, unless its root SCC(s) merely bridge two
  /// or more otherwise-disconnected components of `>= minClusterLines` each.
  /// In that case each component becomes its own cut, every root joins the
  /// component it has the most edges into, and undersized components follow
  /// the root that reaches them. The split is abandoned (bundled cut kept) if
  /// the resulting groups would import each other cyclically or would need
  /// more private widenings than the bundled cut.
  void _commitCone(Set<int> cone) {
    final groups = _splitBridgedCone(cone);
    if (groups == null) {
      _commitCluster(cone, isDisjointIsland: false);
      return;
    }
    final roots = _coneRoots(cone);
    final rootNames = [for (final r in roots) ...sccs[r]]..sort();
    final bridging = {
      for (final r in roots)
        if (groups.where((g) => _dependsOnAnyOf({r}, [g])).length >= 2) r,
    };
    for (final group in groups) {
      if (extractedSccs.length + group.length >= sccs.length) break;
      // A bridging root only forfeits naming rights when it is a small guest
      // in the group; a root holding a third or more of the group's lines is
      // the group's substance.
      final guests = {
        for (final r in bridging)
          if (group.contains(r) && _sccLines(r) * 3 < _setLines(group)) r,
      };
      final declCount = group.fold(0, (s, i) => s + sccs[i].length);
      _commitCluster(
        group,
        isDisjointIsland: false,
        rationale:
            'Sub-component of the ${rootNames.join(', ')} cone '
            '($declCount declaration(s)); shares no edges with its sibling '
            'cut(s) other than through the cone root(s), 0 circular imports.',
        namingSccs: group.difference(guests),
      );
    }
  }

  List<Set<int>>? _splitBridgedCone(Set<int> cone) {
    final roots = _coneRoots(cone);
    if (roots.isEmpty) return null;
    final groups = _weaklyConnectedComponentsOf(cone.difference(roots));
    final largeCount = groups.where((g) => _setLines(g) >= minClusterLines);
    if (largeCount.length < 2) return null;

    for (final root in roots) {
      groups[_mostConnectedGroup(root, groups)].add(root);
    }
    _absorbUndersizedGroups(groups);
    final ordered = _topologicalGroupOrder(groups);
    if (ordered == null || ordered.length < 2) return null;

    final bundledCrossings = _crossingIndex.countCrossings(cone);
    final splitCrossings = ordered.fold(
      0,
      (s, g) => s + _crossingIndex.countCrossings(g),
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
      final larger = _setLines(groups[i]) > _setLines(groups[best]);
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
        if (_setLines(groups[i]) >= minClusterLines) continue;
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
          if (!_dependsOnAnyOf(g, pending.where((o) => !identical(o, g)))) g,
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

  bool _dependsOnAnyOf(Set<int> group, Iterable<Set<int>> others) => group
      .expand((u) => dag[u] ?? const <int>{})
      .any((v) => others.any((o) => o.contains(v)));

  /// SCCs in [cone] with no predecessor inside [cone].
  Set<int> _coneRoots(Set<int> cone) {
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

  int _compareCandidateCones(_ScoredCone a, _ScoredCone b, int neededLines) {
    final aSufficient = a.lines >= neededLines;
    final bSufficient = b.lines >= neededLines;
    if (aSufficient != bSufficient) {
      return aSufficient ? -1 : 1;
    }
    final crossCmp = a.crossings.compareTo(b.crossings);
    if (aSufficient && bSufficient) {
      return crossCmp != 0 ? crossCmp : a.lines.compareTo(b.lines);
    }
    return b.lines != a.lines ? b.lines.compareTo(a.lines) : crossCmp;
  }

  Set<int> _unextractedDownwardClosure(Iterable<int> seeds) {
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

  List<Set<int>> _mergeChildConesToMinimizeCrossings(
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
        c: _unextractedDownwardClosure(coneNodes[c]!),
    };
    return [
      for (final c in survivingChildren)
        if (closures[c]!.isNotEmpty &&
            !(_isAllPrivateGroup(closures[c]!) &&
                closures.entries.any((e) => e.key != c && e.value.contains(c))))
          _CandidateGroup(
            id: _nextCandidateGroupId++,
            sccs: closures[c]!,
            lines: _setLines(closures[c]!),
            crossings: _crossingIndex.countCrossings(closures[c]!),
            isAllPrivate: _isAllPrivateGroup(closures[c]!),
            touchedItems: {
              for (final u in closures[c]!) ..._crossingIndex.itemsByScc[u],
            },
          ),
    ];
  }

  bool _isAllPrivateGroup(Set<int> group) =>
      group.every((idx) => _sccAllPrivate[idx]);

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
    final candLines = _setLines(candidate);
    final bothPrivate = gi.isAllPrivate && gj.isAllPrivate;
    final maxLines = (!requireReduction && !bothPrivate)
        ? targetLines ~/ 2
        : targetLines;
    if (candLines > maxLines || !_isValidDownwardClosedCut(candidate)) {
      return false;
    }
    final crossBefore = gi.crossings + gj.crossings;
    final crossAfter = _crossingIndex.countCrossings(candidate);
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

  void _reabsorbSurplusSmallCuts() {
    if (clusters.length <= 1) return;
    var changed = true;
    while (changed && clusters.length > 1) {
      changed = _tryReabsorbOneSmallCut();
    }
  }

  bool _tryReabsorbOneSmallCut() {
    final sortedIndices = Iterable<int>.generate(clusters.length).toList()
      ..sort(
        (a, b) => clusters[a].totalLines.compareTo(clusters[b].totalLines),
      );
    for (final idx in sortedIndices) {
      final c = clusters[idx];
      if (_remainingLines() + c.totalLines <= targetLines &&
          !_isDependedOnByOtherExtractedClusters(idx)) {
        _removeClusterAt(idx);
        return true;
      }
    }
    return false;
  }

  bool _isDependedOnByOtherExtractedClusters(int clusterIdx) {
    final targetNames = clusters[clusterIdx].declarations
        .map((d) => d.name)
        .toSet();
    for (var i = 0; i < clusters.length; i++) {
      if (i == clusterIdx) continue;
      final depends = clusters[i].declarations.any(
        (d) => d.outgoingIntraFileRefs.any(targetNames.contains),
      );
      if (depends) return true;
    }
    return false;
  }

  void _removeClusterAt(int clusterIdx) {
    final removed = clusters.removeAt(clusterIdx);
    final removedNames = removed.declarations.map((d) => d.name).toSet();
    for (var i = 0; i < sccs.length; i++) {
      if (sccs[i].any(removedNames.contains)) {
        extractedSccs.remove(i);
      }
    }
  }

  bool _isValidDownwardClosedCut(Set<int> candidate) {
    for (final u in candidate) {
      for (final v in dag[u] ?? const <int>{}) {
        if (!candidate.contains(v) && !extractedSccs.contains(v)) {
          return false;
        }
      }
    }
    return true;
  }

  void _extractOversizedSccFallbacks() {
    if (useParts == false) return;
    final preFallbackRemaining = _remainingLines();
    final candidates = [
      for (var i = 0; i < sccs.length; i++)
        if (!extractedSccs.contains(i) &&
            (sccs[i].length > 1 || (useParts == true && sccs[i].length == 1)) &&
            _sccLines(i) > targetLines)
          i,
    ]..sort((a, b) => _sccLines(b).compareTo(_sccLines(a)));
    for (final i in candidates) {
      if (extractedSccs.length + 1 >= sccs.length) break;
      final remainingAfter = _remainingLines() - _sccLines(i);
      if (remainingAfter * 4 >= preFallbackRemaining) {
        _commitCluster({i}, isDisjointIsland: false, forceTier3: true);
      }
    }
  }

  /// Lines left in the file after the committed cuts, measured against the
  /// physical file length so imports, comments, and blank lines count toward
  /// the budget exactly as they do in
  /// [FileSplitReport.estimatedRemainingLines].
  int _remainingLines() => totalLines - _setLines(extractedSccs);

  /// Declarations belonging to [sccIndices], in source order.
  List<DeclarationUnit> _declsOf(Iterable<int> sccIndices) => <DeclarationUnit>[
    for (final idx in sccIndices)
      for (final name in sccs[idx]) ?declsByName[name],
  ]..sort((a, b) => a.startLine.compareTo(b.startLine));

  void _commitCluster(
    Set<int> sccIndices, {
    required bool isDisjointIsland,
    bool forceTier3 = false,
    String? rationale,
    Set<int>? namingSccs,
  }) {
    extractedSccs.addAll(sccIndices);
    final clusterNames = <String>{for (final idx in sccIndices) ...sccs[idx]};
    final decls = _declsOf(sccIndices);
    final namingDecls = (namingSccs == null || namingSccs.isEmpty)
        ? decls
        : _declsOf(namingSccs);

    final (:absorbed, :privTopToWiden, :privMembersToWiden) =
        _classifyBoundaryCrossings(clusterNames, decls);

    final tier =
        (useParts != false && (forceTier3 || privMembersToWiden.length >= 3))
        ? SplitTier.tier3PartDirective
        : (privTopToWiden.length + privMembersToWiden.length == 0
              ? SplitTier.tier1CleanLibrary
              : SplitTier.tier2InternalWidening);
    final clusterDepth = sccIndices
        .map((i) => depths[i] ?? 0)
        .fold(0, math.max);
    final fileName = _suggestFileName(namingDecls, clusterDepth);
    final directive = (tier == SplitTier.tier3PartDirective && useParts == null)
        ? kAskUserPartsPreferenceDirective
        : null;

    clusters.add(
      SplitCluster(
        suggestedFileName: fileName,
        tier: tier,
        topologicalDepth: clusterDepth,
        isDisjointIsland: isDisjointIsland,
        declarations: List.unmodifiable(decls),
        absorbedPrivateHelpers: List.unmodifiable(absorbed),
        privateTopLevelsToWiden: List.unmodifiable(privTopToWiden),
        privateMembersToWiden: List.unmodifiable(privMembersToWiden),
        requiredImports: List.unmodifiable(
          {for (final d in decls) ...d.requiredImportDirectives}.toList()
            ..sort(),
        ),
        exportedPublicSymbols: List.unmodifiable([
          for (final d in decls)
            if (d.isPublic) d.name,
        ]),
        rationale:
            rationale ??
            _buildRationale(isDisjointIsland, tier, clusterDepth, decls),
        agentDirective: directive,
      ),
    );
  }

  ({
    List<String> absorbed,
    List<String> privTopToWiden,
    List<String> privMembersToWiden,
  })
  _classifyBoundaryCrossings(
    Set<String> clusterNames,
    List<DeclarationUnit> decls,
  ) {
    final outsideDecls = [
      for (final entry in declsByName.entries)
        if (!clusterNames.contains(entry.key)) entry.value,
    ];
    final absorbed = <String>[];
    final privTop = <String>{};
    final privMem = <String>{};

    final outsideNames = outsideDecls.map((o) => o.name).toSet();
    for (final d in decls) {
      if (!d.isPublic) {
        final usedOutside = outsideDecls.any(
          (o) => o.outgoingIntraFileRefs.contains(d.name),
        );
        if (usedOutside) {
          privTop.add(d.name);
        } else {
          absorbed.add(d.name);
        }
      }
      privTop.addAll(
        d.outgoingIntraFileRefs.where(
          (r) => outsideNames.contains(r) && r.startsWith('_'),
        ),
      );
      _collectCrossMembers(
        d.privateMemberAccessesByTarget,
        (t) => !clusterNames.contains(t),
        privMem,
      );
    }
    for (final out in outsideDecls) {
      privTop.addAll(
        out.outgoingIntraFileRefs.where(
          (r) => clusterNames.contains(r) && r.startsWith('_'),
        ),
      );
      _collectCrossMembers(
        out.privateMemberAccessesByTarget,
        clusterNames.contains,
        privMem,
      );
    }

    return (
      absorbed: absorbed..sort(),
      privTopToWiden: privTop.toList()..sort(),
      privMembersToWiden: privMem.toList()..sort(),
    );
  }

  void _collectCrossMembers(
    Map<String, Set<String>> accesses,
    bool Function(String) targetFilter,
    Set<String> sink,
  ) {
    for (final entry in accesses.entries) {
      if (targetFilter(entry.key)) {
        sink.addAll(entry.value.map((m) => '${entry.key}.$m'));
      }
    }
  }

  String _buildRationale(
    bool isIsland,
    SplitTier tier,
    int depth,
    List<DeclarationUnit> decls,
  ) {
    if (isIsland) {
      return 'Disconnected component (LCOM4 island) '
          'with 0 edges to surviving symbols.';
    }
    if (tier == SplitTier.tier3PartDirective) {
      return 'Mutually recursive SCC / sealed group or >= 3 cross-class '
          'private member accesses.';
    }
    return 'DAG Layer-$depth extraction (${decls.length} declaration(s)); '
        'surviving higher-layer symbols depend downward on this cluster '
        'with 0 circular imports.';
  }

  String _suggestFileName(List<DeclarationUnit> decls, int depth) {
    final hasPublic = decls.any((d) => d.isPublic);
    if (!hasPublic && decls.length >= 5) {
      return _deduplicateFileName('${stem}_helpers.dart');
    }
    final primary = _dominantDeclaration(decls);
    final clean = primary.name.replaceFirst(RegExp('^_+'), '');
    final snake = clean
        .replaceAllMapped(RegExp('([a-z0-9])([A-Z])'), (m) => '${m[1]}_${m[2]}')
        .toLowerCase();

    final base = snake.isEmpty || snake == stem
        ? '${stem}_layer_$depth.dart'
        : '$snake.dart';
    return _deduplicateFileName(base);
  }

  /// The public declaration with the most lines (ties go to the earliest in
  /// source order, since [decls] is sorted by start line). Falls back to the
  /// largest declaration overall when the cluster has no public symbols.
  DeclarationUnit _dominantDeclaration(List<DeclarationUnit> decls) {
    final publics = decls.where((d) => d.isPublic);
    final pool = publics.isEmpty ? decls : publics;
    return pool.reduce((a, b) => b.lineCount > a.lineCount ? b : a);
  }

  String _deduplicateFileName(String initial) {
    var candidate = initial;
    var counter = 2;
    while (!usedFileNames.add(candidate)) {
      candidate = '${p.basenameWithoutExtension(initial)}_$counter.dart';
      counter++;
    }
    return candidate;
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
class _BoundaryCrossingIndex {
  final List<int> spanSizes;
  final List<List<int>> itemsByScc;
  final List<int> _hits;
  final List<int> _touched = [];

  _BoundaryCrossingIndex._(this.spanSizes, this.itemsByScc)
    : _hits = List<int>.filled(spanSizes.length, 0);

  factory _BoundaryCrossingIndex.build(
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
    return _BoundaryCrossingIndex._(spanSizes, itemsByScc);
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
