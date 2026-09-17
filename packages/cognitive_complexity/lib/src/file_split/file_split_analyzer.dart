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
    int targetLines = 300,
    int minClusterLines = 40,
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
    );
  }

  /// Analyzes an already-resolved [unitResult].
  FileSplitReport analyzeResolvedUnit(
    ResolvedUnitResult unitResult, {
    String? displayPath,
    int targetLines = 300,
    int minClusterLines = 40,
  }) {
    final pathStr = displayPath ?? unitResult.path;
    final totalLines = unitResult.lineInfo.lineCount;
    final populated = harvestDeclarationUnits(
      unitResult.unit,
      unitResult.lineInfo,
    );

    if (populated.length <= 1) {
      return FileSplitReport(
        filePath: pathStr,
        totalLines: totalLines,
        declarationCount: populated.length,
        lcom4Islands: populated.isEmpty ? 0 : 1,
        sccCount: populated.length,
        maxTopologicalDepth: 0,
        clusters: const [],
        survivingDeclarations: populated.values.toList(),
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
      declsByName: populated,
      sccs: sccs,
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
    );
  }
}

class _ExtractionCutPlanner {
  final String filePath;
  final int targetLines;
  final int minClusterLines;
  final Map<String, DeclarationUnit> declsByName;
  final List<List<String>> sccs;
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
    required this.declsByName,
    required this.sccs,
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
    _extractTopologicalLayers();
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

  void _extractTopologicalLayers() {
    final anchorScc = _findPrimaryAnchorScc();
    final maxDepth = depths.values.fold(0, math.max);
    for (var d = 0; d < maxDepth; d++) {
      if (_remainingLines() <= targetLines) break;
      final candidates = [
        for (var i = 0; i < sccs.length; i++)
          if (!extractedSccs.contains(i) && i != anchorScc && depths[i] == d) i,
      ];
      _batchAndCommitLayer(candidates);
    }
  }

  int? _findPrimaryAnchorScc() {
    final totalDeclLines = _setLines(Iterable<int>.generate(sccs.length));
    var bestIdx = -1;
    var bestLines = 0;
    for (var i = 0; i < sccs.length; i++) {
      final lines = _sccLines(i);
      if (lines > bestLines) {
        bestLines = lines;
        bestIdx = i;
      }
    }
    return bestLines * 2 >= totalDeclLines ? bestIdx : null;
  }

  void _batchAndCommitLayer(List<int> candidates) {
    final batch = <int>{};
    var batchLines = 0;
    for (final idx in candidates) {
      final lines = _sccLines(idx);
      if (batchLines > 0 && batchLines + lines > targetLines) {
        _commitCluster(Set.of(batch), isDisjointIsland: false);
        batch.clear();
        batchLines = 0;
      }
      batch.add(idx);
      batchLines += lines;
    }
    if (batchLines >= minClusterLines) {
      _commitCluster(Set.of(batch), isDisjointIsland: false);
    }
  }

  void _extractOversizedSccFallbacks() {
    for (var i = 0; i < sccs.length; i++) {
      if (!extractedSccs.contains(i) &&
          sccs[i].length > 1 &&
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
    if (forceTier3 || privMemCount >= 3) return SplitTier.tier3PartDirective;
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
      return 'Disconnected component (LCOM4 island) with 0 edges to surviving symbols.';
    }
    if (tier == SplitTier.tier3PartDirective) {
      return 'Mutually recursive SCC / sealed group or >= 3 cross-class private member accesses.';
    }
    return 'DAG Layer-$depth extraction (${decls.length} declaration(s)); '
        'surviving higher-layer symbols depend downward on this cluster with 0 circular imports.';
  }

  String _suggestFileName(List<DeclarationUnit> decls, int depth) {
    final primary = decls.firstWhere((d) => d.isPublic, orElse: () => decls[0]);
    final clean = primary.name.replaceFirst(RegExp('^_+'), '');
    final snake = clean
        .replaceAllMapped(RegExp('([a-z0-9])([A-Z])'), (m) => '${m[1]}_${m[2]}')
        .toLowerCase();

    var candidate = snake == stem ? '${stem}_layer_$depth.dart' : '$snake.dart';
    var counter = 2;
    while (!usedFileNames.add(candidate)) {
      candidate = '${p.basenameWithoutExtension(candidate)}_$counter.dart';
      counter++;
    }
    return candidate;
  }
}
