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
    final absPath = p.canonicalize(File(filePath).absolute.path);
    final unitResult = await AnalysisContextHelper.resolveFile(
      absPath,
      sdkPath: sdkPath,
    );
    return analyzeResolvedUnit(
      unitResult,
      displayPath: filePath,
      targetLines: targetLines,
      minClusterLines: minClusterLines,
      useParts: useParts,
    );
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
        survivingDeclarations: populated.values.toList(),
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
      targetLines: targetLines,
      minClusterLines: minClusterLines,
      useParts: useParts,
      declsByName: populated,
      sccs: sccs,
      dag: sccDag,
      depths: depths,
      islands: islands,
    );
    final (:clusters, :surviving) = planner.plan();

    return FileSplitReport(
      filePath: pathStr,
      totalLines: totalLines,
      declarationCount: populated.length,
      lcom4Islands: islands.length,
      sccCount: sccs.length,
      maxTopologicalDepth: maxDepth,
      clusters: clusters,
      survivingDeclarations: surviving,
      targetLines: targetLines,
      useParts: useParts,
    );
  }
}

class _ExtractionCutPlanner {
  final String filePath;
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

  _ExtractionCutPlanner({
    required this.filePath,
    required this.targetLines,
    required this.minClusterLines,
    required this.useParts,
    required this.declsByName,
    required this.sccs,
    required this.dag,
    required this.depths,
    required this.islands,
  }) : stem = p.basenameWithoutExtension(filePath),
       usedFileNames = <String>{p.basename(filePath)};

  int _sccLines(int idx) =>
      sccs[idx].fold(0, (s, n) => s + (declsByName[n]?.lineCount ?? 0));

  int _setLines(Iterable<int> indices) =>
      indices.fold(0, (s, idx) => s + _sccLines(idx));

  ({List<SplitCluster> clusters, List<DeclarationUnit> surviving}) plan() {
    _extractDisjointIslands();
    _extractDominatorCones();
    _extractOversizedSccFallbacks();

    final surviving = <DeclarationUnit>[
      for (var i = 0; i < sccs.length; i++)
        if (!extractedSccs.contains(i))
          for (final name in sccs[i]) ?declsByName[name],
    ]..sort((a, b) => a.startLine.compareTo(b.startLine));

    return (clusters: clusters, surviving: surviving);
  }

  void _extractDisjointIslands() {
    if (islands.length <= 1) return;
    final sortedIslands = [...islands]
      ..sort((a, b) => _setLines(b).compareTo(_setLines(a)));

    for (final island in sortedIslands.skip(1)) {
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

    for (var i = 0; i < sccs.length; i++) {
      if (!idom.containsKey(i)) {
        _extractNodeCone(i, idom, domTree, coneSizes, coneNodes);
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

    if (!idom.containsKey(node)) {
      _maybeCommitRootCone(coneNodes[node]!, coneSizes[node]!);
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
    final (:extractable, :kept) = _partitionExtractableGroups(groups);
    var remainingInNode = _setLines({
      node,
      for (final c in survivingChildren) ...coneNodes[c]!,
    });

    for (final g in extractable) {
      final unextractedG = g.difference(extractedSccs);
      if (_shouldExtractChildGroup(unextractedG, remainingInNode)) {
        _commitCluster(unextractedG, isDisjointIsland: false);
        remainingInNode = _setLines(
          {
            node,
            for (final c in survivingChildren) ...coneNodes[c]!,
          }.difference(extractedSccs),
        );
      } else if (unextractedG.isNotEmpty) {
        kept.add(unextractedG);
      }
    }
    return <int>{node, for (final g in kept) ...g}.difference(extractedSccs);
  }

  ({List<Set<int>> extractable, List<Set<int>> kept})
  _partitionExtractableGroups(List<Set<int>> groups) {
    final extractable = <Set<int>>[];
    final kept = <Set<int>>[];
    for (final g in groups) {
      final lines = _setLines(g);
      if (lines >= minClusterLines &&
          lines <= targetLines &&
          _isValidDownwardClosedCut(g)) {
        extractable.add(g);
      } else {
        kept.add(g);
      }
    }
    extractable.sort(_compareCandidateCones);
    return (extractable: extractable, kept: kept);
  }

  int _compareCandidateCones(Set<int> a, Set<int> b) {
    final crossCmp = _countBoundaryCrossings(
      a,
    ).compareTo(_countBoundaryCrossings(b));
    return crossCmp != 0 ? crossCmp : _setLines(b).compareTo(_setLines(a));
  }

  bool _shouldExtractChildGroup(Set<int> group, int remainingInNode) =>
      remainingInNode > targetLines &&
      _setLines(group) >= minClusterLines &&
      _isValidDownwardClosedCut(group);

  void _maybeCommitRootCone(Set<int> nodes, int size) {
    if (_remainingLines() > targetLines &&
        size >= minClusterLines &&
        size <= targetLines &&
        size < _remainingLines() &&
        _isValidDownwardClosedCut(nodes)) {
      _commitCluster(nodes, isDisjointIsland: false);
    }
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
    while (_tryMergeOneCrossingPair(groups, requireReduction: true)) {}
    while (_tryMergeOneCrossingPair(groups, requireReduction: false)) {}
    return groups;
  }

  List<Set<int>> _initialDownwardClosedChildGroups(
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
            !_isCoveredPrivateLeaf(c, closures[c]!, closures))
          closures[c]!,
    ];
  }

  bool _isCoveredPrivateLeaf(
    int child,
    Set<int> closed,
    Map<int, Set<int>> closures,
  ) {
    if (!_isAllPrivateGroup(closed)) return false;
    return closures.entries.any(
      (e) => e.key != child && e.value.containsAll(closed),
    );
  }

  bool _isAllPrivateGroup(Set<int> group) => group.every(
    (idx) => sccs[idx].every((n) => !(declsByName[n]?.isPublic ?? true)),
  );

  bool _tryMergeOneCrossingPair(
    List<Set<int>> groups, {
    required bool requireReduction,
  }) {
    for (var i = 0; i < groups.length; i++) {
      for (var j = i + 1; j < groups.length; j++) {
        if (_mergePairIfEligible(
          groups,
          i,
          j,
          requireReduction: requireReduction,
        )) {
          return true;
        }
      }
    }
    return false;
  }

  bool _mergePairIfEligible(
    List<Set<int>> groups,
    int i,
    int j, {
    required bool requireReduction,
  }) {
    if (!requireReduction &&
        (!_isAllPrivateGroup(groups[i]) || !_isAllPrivateGroup(groups[j]))) {
      return false;
    }
    final candidate = <int>{...groups[i], ...groups[j]};
    if (_setLines(candidate) > targetLines ||
        !_isValidDownwardClosedCut(candidate)) {
      return false;
    }
    final crossBefore =
        _countBoundaryCrossings(groups[i]) + _countBoundaryCrossings(groups[j]);
    final crossAfter = _countBoundaryCrossings(candidate);
    final worse = requireReduction
        ? crossAfter >= crossBefore
        : crossAfter > crossBefore;
    if (worse) return false;

    final removedA = groups[i];
    final removedB = groups[j];
    groups
      ..remove(removedA)
      ..remove(removedB)
      ..add(candidate);
    return true;
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

  int _countBoundaryCrossings(Set<int> sccIndices) {
    final clusterNames = <String>{for (final idx in sccIndices) ...sccs[idx]};
    final decls = <DeclarationUnit>[
      for (final name in clusterNames) ?declsByName[name],
    ];
    final (:absorbed, :privTopToWiden, :privMembersToWiden) =
        _classifyBoundaryCrossings(clusterNames, decls);
    return privTopToWiden.length + privMembersToWiden.length;
  }

  void _extractOversizedSccFallbacks() {
    if (useParts == false) return;
    for (var i = 0; i < sccs.length; i++) {
      final allowSingleClassPart = useParts == true && sccs[i].length == 1;
      if (!extractedSccs.contains(i) &&
          (sccs[i].length > 1 || allowSingleClassPart) &&
          _sccLines(i) > targetLines) {
        _commitCluster({i}, isDisjointIsland: false, forceTier3: true);
      }
    }
  }

  int _remainingLines() => _setLines(
    Iterable<int>.generate(
      sccs.length,
    ).where((i) => !extractedSccs.contains(i)),
  );

  void _commitCluster(
    Set<int> sccIndices, {
    required bool isDisjointIsland,
    bool forceTier3 = false,
  }) {
    extractedSccs.addAll(sccIndices);
    final clusterNames = <String>{for (final idx in sccIndices) ...sccs[idx]};
    final decls = <DeclarationUnit>[
      for (final name in clusterNames) ?declsByName[name],
    ]..sort((a, b) => a.startLine.compareTo(b.startLine));

    final (:absorbed, :privTopToWiden, :privMembersToWiden) =
        _classifyBoundaryCrossings(clusterNames, decls);

    final tier = _determineTier(
      forceTier3,
      privTopToWiden.length,
      privMembersToWiden.length,
    );
    final clusterDepth = sccIndices
        .map((i) => depths[i] ?? 0)
        .fold(0, math.max);
    final fileName = _suggestFileName(decls, clusterDepth);
    final directive = (tier == SplitTier.tier3PartDirective && useParts == null)
        ? kAskUserPartsPreferenceDirective
        : null;

    clusters.add(
      SplitCluster(
        suggestedFileName: fileName,
        tier: tier,
        topologicalDepth: clusterDepth,
        isDisjointIsland: isDisjointIsland,
        declarations: decls,
        absorbedPrivateHelpers: absorbed,
        privateTopLevelsToWiden: privTopToWiden,
        privateMembersToWiden: privMembersToWiden,
        requiredImports: {
          for (final d in decls) ...d.requiredImportDirectives,
        }.toList()..sort(),
        exportedPublicSymbols: [
          for (final d in decls)
            if (d.isPublic) d.name,
        ],
        rationale: _buildRationale(isDisjointIsland, tier, clusterDepth, decls),
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

    _classifyInClusterDecls(
      decls,
      clusterNames,
      outsideDecls,
      absorbed,
      privTop,
      privMem,
    );
    _classifyOutsideDecls(outsideDecls, clusterNames, privTop, privMem);

    return (
      absorbed: absorbed..sort(),
      privTopToWiden: privTop.toList()..sort(),
      privMembersToWiden: privMem.toList()..sort(),
    );
  }

  void _classifyInClusterDecls(
    List<DeclarationUnit> decls,
    Set<String> clusterNames,
    List<DeclarationUnit> outsideDecls,
    List<String> absorbed,
    Set<String> privTop,
    Set<String> privMem,
  ) {
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
  }

  void _classifyOutsideDecls(
    List<DeclarationUnit> outsideDecls,
    Set<String> clusterNames,
    Set<String> privTop,
    Set<String> privMem,
  ) {
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

  SplitTier _determineTier(
    bool forceTier3,
    int privTopCount,
    int privMemCount,
  ) {
    if (useParts != false && (forceTier3 || privMemCount >= 3)) {
      return SplitTier.tier3PartDirective;
    }
    if (privTopCount + privMemCount == 0) return SplitTier.tier1CleanLibrary;
    return SplitTier.tier2InternalWidening;
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
    final primary = decls.firstWhere((d) => d.isPublic, orElse: () => decls[0]);
    final clean = primary.name.replaceFirst(RegExp('^_+'), '');
    final snake = clean
        .replaceAllMapped(RegExp('([a-z0-9])([A-Z])'), (m) => '${m[1]}_${m[2]}')
        .toLowerCase();

    final base = snake == stem ? '${stem}_layer_$depth.dart' : '$snake.dart';
    return _deduplicateFileName(base);
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
