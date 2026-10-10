import 'dart:math' as math;

import 'package:path/path.dart' as p;

import 'inherited_import_cycles.dart';
import 'models.dart';

/// Inputs of a committed cut, kept so the cut can be rebuilt in place when
/// sibling types are pulled into it.
typedef CutSpec = ({
  Set<int> sccIndices,
  bool isDisjointIsland,
  bool forceTier3,
  String? rationale,
  Set<int>? namingSccs,
});

/// Public declaration kinds that count as types for cut naming.
const _typeKinds = {'class', 'enum', 'extension type', 'typedef', 'mixin'};

/// Builds [SplitCluster] recommendations from committed SCC cuts, classifying
/// private boundary crossings and selecting collision-free target filenames.
class ClusterBuilder {
  final String stem;
  final bool? useParts;
  final Map<String, DeclarationUnit> declsByName;
  final List<List<String>> sccs;
  final Map<int, int> depths;
  final Map<String, InheritedImportCycle> importCycles;
  final Set<String> usedFileNames;

  ClusterBuilder({
    required String filePath,
    required this.useParts,
    required this.declsByName,
    required this.sccs,
    required this.depths,
    required this.importCycles,
  }) : stem = p.basenameWithoutExtension(filePath),
       usedFileNames = <String>{p.basename(filePath)};

  /// Declarations belonging to [sccIndices], in source order.
  List<DeclarationUnit> declsOf(Iterable<int> sccIndices) => <DeclarationUnit>[
    for (final idx in sccIndices)
      for (final name in sccs[idx]) ?declsByName[name],
  ]..sort((a, b) => a.startLine.compareTo(b.startLine));

  SplitCluster buildCluster(CutSpec spec, {List<String> notes = const []}) {
    final (
      :sccIndices,
      :isDisjointIsland,
      :forceTier3,
      :rationale,
      :namingSccs,
    ) = spec;
    final clusterNames = <String>{for (final idx in sccIndices) ...sccs[idx]};
    final decls = declsOf(sccIndices);
    final namingDecls = (namingSccs == null || namingSccs.isEmpty)
        ? decls
        : declsOf(namingSccs);

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
    final requiredImports = {
      for (final d in decls) ...d.requiredImportDirectives,
    }.toList()..sort();

    final cycles = applyInheritedCycles(
      requiredImports,
      importCycles,
      rationale ?? _buildRationale(isDisjointIsland, tier, clusterDepth, decls),
    );

    return SplitCluster(
      suggestedFileName: fileName,
      tier: tier,
      topologicalDepth: clusterDepth,
      isDisjointIsland: isDisjointIsland,
      declarations: List.unmodifiable(decls),
      absorbedPrivateHelpers: List.unmodifiable(absorbed),
      privateTopLevelsToWiden: List.unmodifiable(privTopToWiden),
      privateMembersToWiden: List.unmodifiable(privMembersToWiden),
      requiredImports: List.unmodifiable(requiredImports),
      exportedPublicSymbols: List.unmodifiable([
        for (final d in decls)
          if (d.isPublic) d.name,
      ]),
      rationale: cycles.rationale,
      agentDirective: directive,
      notes: List.unmodifiable(notes),
      warnings: cycles.warnings,
      inheritedCycles: cycles.info,
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
    if (_isTypeCluster(decls)) {
      return _deduplicateFileName('${stem}_models.dart');
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

  /// Whether [decls] form a type cluster: at least two public type
  /// declarations make up at least half of their lines, and either the
  /// longest public declaration is not a type (so the cut would otherwise be
  /// named after a function) or no single type holds more than half of the
  /// type lines.
  bool _isTypeCluster(List<DeclarationUnit> decls) {
    final types = [
      for (final d in decls)
        if (d.isPublic && _typeKinds.contains(d.kind)) d,
    ];
    if (types.length < 2) return false;
    final typeLines = types.fold(0, (s, d) => s + d.lineCount);
    final allLines = decls.fold(0, (s, d) => s + d.lineCount);
    if (typeLines * 2 < allLines) return false;
    final dominant = _dominantDeclaration(decls);
    return !_typeKinds.contains(dominant.kind) ||
        dominant.lineCount * 2 <= typeLines;
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
