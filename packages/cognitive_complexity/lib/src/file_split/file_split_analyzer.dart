import 'dart:io';
import 'dart:math' as math;

import 'package:analytica/analyzer.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:path/path.dart' as p;

import 'ast_declaration_harvester.dart';
import 'cluster_builder.dart';
import 'cone_splitter.dart';
import 'graph_topology.dart';
import 'inherited_import_cycles.dart';
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
    importCycles: inheritedImportCycles(unitResult),
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

  /// Inherited import cycles keyed by the import directive source text.
  final Map<String, InheritedImportCycle> importCycles;

  final extractedSccs = <int>{};
  final clusters = <SplitCluster>[];

  /// Parallel to [clusters].
  final _specs = <CutSpec>[];
  late final ConeSplitter _coneSplitter = ConeSplitter(
    targetLines: targetLines,
    minClusterLines: minClusterLines,
    declsByName: declsByName,
    sccs: sccs,
    dag: dag,
    extractedSccs: extractedSccs,
  );
  late final ClusterBuilder _clusterBuilder = ClusterBuilder(
    filePath: filePath,
    useParts: useParts,
    declsByName: declsByName,
    sccs: sccs,
    depths: depths,
    importCycles: importCycles,
  );

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
    this.importCycles = const {},
  });

  int _sccLines(int idx) => _coneSplitter.sccLines(idx);

  int _setLines(Iterable<int> indices) => _coneSplitter.setLines(indices);

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
    _keepSiblingTypesTogether();

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

    final mergedGroups = _coneSplitter.mergeChildConesToMinimizeCrossings(
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

    if (totalConeLines <= targetLines &&
        _coneSplitter.isValidDownwardClosedCut(mergedAll)) {
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
    final groups = _coneSplitter.mergeChildConesToMinimizeCrossings(
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
    final eligible = <ScoredCone>[];
    for (final g in groups) {
      final unextracted = _coneSplitter.unextractedDownwardClosure(g);
      final lines = _setLines(unextracted);
      final withinRem =
          !requireSmallerThanRemaining ||
          (lines < remLines &&
              (unextracted.length < remSccCount ||
                  _coneSplitter.splitBridgedCone(unextracted) != null));
      if (lines >= minClusterLines &&
          lines <= targetLines &&
          withinRem &&
          _coneSplitter.isValidDownwardClosedCut(unextracted)) {
        eligible.add((
          cone: unextracted,
          lines: lines,
          crossings: _coneSplitter.crossingIndex.countCrossings(unextracted),
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
    final groups = _coneSplitter.splitBridgedCone(cone);
    if (groups == null) {
      _commitCluster(cone, isDisjointIsland: false);
      return;
    }
    final roots = _coneSplitter.coneRoots(cone);
    final rootNames = [for (final r in roots) ...sccs[r]]..sort();
    final bridging = {
      for (final r in roots)
        if (groups
                .where((g) => _coneSplitter.dependsOnAnyOf({r}, [g]))
                .length >=
            2)
          r,
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

  int _compareCandidateCones(ScoredCone a, ScoredCone b, int neededLines) {
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
    _specs.removeAt(clusterIdx);
    final removedNames = removed.declarations.map((d) => d.name).toSet();
    for (var i = 0; i < sccs.length; i++) {
      if (sccs[i].any(removedNames.contains)) {
        extractedSccs.remove(i);
      }
    }
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

  void _commitCluster(
    Set<int> sccIndices, {
    required bool isDisjointIsland,
    bool forceTier3 = false,
    String? rationale,
    Set<int>? namingSccs,
  }) {
    extractedSccs.addAll(sccIndices);
    final spec = (
      sccIndices: sccIndices,
      isDisjointIsland: isDisjointIsland,
      forceTier3: forceTier3,
      rationale: rationale,
      namingSccs: namingSccs,
    );
    _specs.add(spec);
    clusters.add(_clusterBuilder.buildCluster(spec));
  }

  /// Pulls public leaf types that share a sibling key (see [_siblingKey])
  /// with a leaf type already moved by a cut into that cut, when doing so
  /// keeps the cut within budget and adds no boundary crossings. Once every
  /// cut has pulled, siblings still left in the source file are reported in
  /// the notes of the first cut that moves a type of the same key.
  void _keepSiblingTypesTogether() {
    final keysByCut = [
      for (var i = 0; i < clusters.length; i++)
        _specs[i].isDisjointIsland ? const <String>{} : _siblingKeysOf(i),
    ];
    final pulledByCut = [
      for (var i = 0; i < clusters.length; i++)
        _pullSiblings(_specs[i].sccIndices, keysByCut[i]),
    ];
    final noted = <String>{};
    for (var i = 0; i < clusters.length; i++) {
      final leftBehind = [
        for (final name in _unextractedSiblings(keysByCut[i]))
          if (noted.add(name)) name,
      ];
      _rebuildWithSiblings(i, pulledByCut[i], leftBehind);
    }
  }

  Set<String> _siblingKeysOf(int i) => {
    for (final d in clusters[i].declarations)
      if (d.outgoingIntraFileRefs.isEmpty) ?_siblingKey(d),
  };

  void _rebuildWithSiblings(
    int i,
    Map<int, String> pulled,
    List<String> leftBehind,
  ) {
    if (pulled.isEmpty && leftBehind.isEmpty) return;
    final spec = _specs[i];
    final namingSccs = spec.namingSccs;
    final grown = (
      sccIndices: {...spec.sccIndices, ...pulled.keys},
      isDisjointIsland: spec.isDisjointIsland,
      forceTier3: spec.forceTier3,
      rationale: spec.rationale,
      namingSccs: namingSccs == null ? null : {...namingSccs, ...pulled.keys},
    );
    _clusterBuilder.usedFileNames.remove(clusters[i].suggestedFileName);
    _specs[i] = grown;
    clusters[i] = _clusterBuilder.buildCluster(
      grown,
      notes: [
        if (pulled.isNotEmpty)
          'sibling type(s) ${pulled.values.join(', ')} kept with this cut '
              '(same kind as a type it moves)',
        if (leftBehind.isNotEmpty)
          'sibling type(s) ${leftBehind.join(', ')} left in '
              '${p.basename(filePath)} (they reference declarations that '
              'stay behind, are coupled to them, or would exceed the '
              'budget)',
      ],
    );
  }

  /// Pulls the unextracted siblings matching [keys] that fit into [cut]: a
  /// single-declaration SCC whose refs stay inside the grown cut, within
  /// budget, adding no boundary crossings, and leaving the source non-empty.
  Map<int, String> _pullSiblings(Set<int> cut, Set<String> keys) {
    final pulled = <int, String>{};
    if (keys.isEmpty) return pulled;
    for (var s = 0; s < sccs.length; s++) {
      if (extractedSccs.contains(s) || _siblingsIn(s, keys).isEmpty) continue;
      final grown = {...cut, ...pulled.keys, s};
      final fits =
          sccs[s].length == 1 &&
          extractedSccs.length + 1 < sccs.length &&
          (dag[s] ?? const <int>{}).every(grown.contains) &&
          _setLines(grown) <= targetLines &&
          _coneSplitter.crossingIndex.countCrossings(grown) <=
              _coneSplitter.crossingIndex.countCrossings(grown.difference({s}));
      if (fits) {
        pulled[s] = sccs[s].single;
        extractedSccs.add(s);
      }
    }
    return pulled;
  }

  /// Declarations matching [keys] in SCCs that no cut moves.
  List<String> _unextractedSiblings(Set<String> keys) => [
    if (keys.isNotEmpty)
      for (var s = 0; s < sccs.length; s++)
        if (!extractedSccs.contains(s)) ..._siblingsIn(s, keys),
  ];

  List<String> _siblingsIn(int scc, Set<String> keys) => [
    for (final name in sccs[scc])
      if (declsByName[name] case final d? when keys.contains(_siblingKey(d)))
        name,
  ];

  /// Groups value-like public types that belong together: extension types by
  /// representation type, and enums. `null` for every other declaration.
  static String? _siblingKey(DeclarationUnit d) {
    if (!d.isPublic) return null;
    return switch (d.kind) {
      'extension type' => 'extension type on ${d.representationType}',
      'enum' => 'enum',
      _ => null,
    };
  }
}
