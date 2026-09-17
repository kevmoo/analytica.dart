/// Data models for the resolved-AST file decomposition (`file_split`) advisor.
library;

/// The 3-Tier File Decomposition classification (analogous to `data_flow`'s
/// 3-Tier Function Decomposition Rubric).
enum SplitTier {
  /// Tier 1: Disjoint island (`LCOM4 >= 2`) or leaf-first DAG layer with
  /// 0 circular edges, 0 `sealed` boundary violations, and 0 cross-cut
  /// `_private` widenings (all private helpers are single-dominator absorbed).
  tier1CleanLibrary('Tier 1: Clean Library Split (import + export show)'),

  /// Tier 2: One-way acyclic DAG cut that requires widening 1–3 shared
  /// `_private` helpers/members to `@internal` inside `lib/src/`.
  tier2InternalWidening('Tier 2: Controlled @internal Widening Split'),

  /// Tier 3: Inseparable SCC cycle, massive `sealed` hierarchy, or dense
  /// cross-class `_private` member web (`>= 3` members) requiring `part` /
  /// `part of` (or interface inversion).
  tier3PartDirective('Tier 3: Library part / part of Split (Gated)');

  final String label;
  const SplitTier(this.label);
}

/// A single top-level declaration within an analyzed Dart source file.
class DeclarationUnit {
  final String name;
  final String kind;
  final int startLine;
  final int endLine;
  final bool isPublic;
  final bool isSealed;
  final Set<String> outgoingIntraFileRefs;
  final Map<String, Set<String>> privateMemberAccessesByTarget;
  final Set<String> requiredImportDirectives;
  final Set<String> hardPinnedPeers;

  const DeclarationUnit({
    required this.name,
    required this.kind,
    required this.startLine,
    required this.endLine,
    required this.isPublic,
    required this.isSealed,
    required this.outgoingIntraFileRefs,
    required this.privateMemberAccessesByTarget,
    required this.requiredImportDirectives,
    required this.hardPinnedPeers,
  });

  int get lineCount => endLine >= startLine ? endLine - startLine + 1 : 0;

  Map<String, dynamic> toJson() => {
    'name': name,
    'kind': kind,
    'start_line': startLine,
    'end_line': endLine,
    'lines': lineCount,
    'is_public': isPublic,
    'is_sealed': isSealed,
    'outgoing_refs': outgoingIntraFileRefs.toList()..sort(),
    if (privateMemberAccessesByTarget.isNotEmpty)
      'private_member_accesses': {
        for (final entry in privateMemberAccessesByTarget.entries)
          entry.key: entry.value.toList()..sort(),
      },
  };
}

/// A recommended extraction cut produced by `FileSplitAnalyzer`.
class SplitCluster {
  final String suggestedFileName;
  final SplitTier tier;
  final int topologicalDepth;
  final bool isDisjointIsland;
  final List<DeclarationUnit> declarations;
  final List<String> absorbedPrivateHelpers;
  final List<String> privateTopLevelsToWiden;
  final List<String> privateMembersToWiden;
  final List<String> requiredImports;
  final List<String> exportedPublicSymbols;
  final String rationale;

  const SplitCluster({
    required this.suggestedFileName,
    required this.tier,
    required this.topologicalDepth,
    required this.isDisjointIsland,
    required this.declarations,
    required this.absorbedPrivateHelpers,
    required this.privateTopLevelsToWiden,
    required this.privateMembersToWiden,
    required this.requiredImports,
    required this.exportedPublicSymbols,
    required this.rationale,
  });

  int get totalLines => declarations.fold(0, (sum, d) => sum + d.lineCount);

  String? get zeroChurnExportDirective {
    if (tier == SplitTier.tier3PartDirective) {
      return "part '$suggestedFileName';";
    }
    if (exportedPublicSymbols.isEmpty) return null;
    final symbols = exportedPublicSymbols.join(', ');
    return "export '$suggestedFileName' show $symbols;";
  }

  Map<String, dynamic> toJson() => {
    'suggested_file': suggestedFileName,
    'tier': tier.name,
    'tier_label': tier.label,
    'topological_depth': topologicalDepth,
    'is_disjoint_island': isDisjointIsland,
    'total_lines': totalLines,
    'rationale': rationale,
    'declarations': declarations.map((d) => d.toJson()).toList(),
    'absorbed_private_helpers': absorbedPrivateHelpers,
    'private_top_levels_to_widen': privateTopLevelsToWiden,
    'private_members_to_widen': privateMembersToWiden,
    'required_imports': requiredImports,
    'exported_public_symbols': exportedPublicSymbols,
    'zero_churn_directive': zeroChurnExportDirective,
  };

  void writeText(StringBuffer buf, int cutIndex, String originalFilePath) {
    buf
      ..writeln()
      ..writeln('[Cut $cutIndex - ${tier.label}]')
      ..writeln('  Suggested File: $suggestedFileName (~$totalLines lines)')
      ..writeln('  Rationale: $rationale')
      ..writeln('  Move Declarations (${declarations.length}):');
    for (final d in declarations) {
      final absorbed = absorbedPrivateHelpers.contains(d.name)
          ? ' [private — single-dominator absorbed]'
          : '';
      buf.writeln(
        '    - ${d.kind} ${d.name} '
        '(L${d.startLine}-${d.endLine}, ${d.lineCount} lines)$absorbed',
      );
    }
    _writeWidenings(buf);
    if (requiredImports.isNotEmpty) {
      buf.writeln('  Required Imports for $suggestedFileName:');
      for (final imp in requiredImports) {
        buf.writeln('    $imp');
      }
    }
    final bridge = zeroChurnExportDirective;
    if (bridge != null) {
      buf
        ..writeln('  Zero-Churn Bridge for $originalFilePath:')
        ..writeln("    + import '$suggestedFileName';")
        ..writeln('    + $bridge');
    }
  }

  void _writeWidenings(StringBuffer buf) {
    if (privateTopLevelsToWiden.isEmpty && privateMembersToWiden.isEmpty) {
      buf.writeln('  Cross-Cut Private Widenings: None (0)');
      return;
    }
    buf.writeln('  Cross-Cut Private Widenings Required (@internal):');
    for (final sym in privateTopLevelsToWiden) {
      final widened = sym.startsWith('_') ? sym.substring(1) : sym;
      buf.writeln('    - Widen `$sym` -> `@internal $widened`');
    }
    for (final mem in privateMembersToWiden) {
      buf.writeln('    - Widen member `$mem` -> `@internal`');
    }
  }
}

/// Complete decomposition report for an analyzed Dart file.
class FileSplitReport {
  final String filePath;
  final int totalLines;
  final int targetLines;
  final int declarationCount;
  final int lcom4Islands;
  final int sccCount;
  final int maxTopologicalDepth;
  final List<SplitCluster> clusters;
  final List<DeclarationUnit> survivingDeclarations;

  const FileSplitReport({
    required this.filePath,
    required this.totalLines,
    this.targetLines = 300,
    required this.declarationCount,
    required this.lcom4Islands,
    required this.sccCount,
    required this.maxTopologicalDepth,
    required this.clusters,
    required this.survivingDeclarations,
  });

  int get extractedLines => clusters.fold(0, (sum, c) => sum + c.totalLines);

  int get estimatedRemainingLines =>
      (totalLines - extractedLines).clamp(1, totalLines);

  Map<String, dynamic> toJson() => {
    'file': filePath,
    'total_lines': totalLines,
    'declaration_count': declarationCount,
    'lcom4_islands': lcom4Islands,
    'scc_count': sccCount,
    'max_topological_depth': maxTopologicalDepth,
    'extracted_lines': extractedLines,
    'estimated_remaining_lines': estimatedRemainingLines,
    'clusters': clusters.map((c) => c.toJson()).toList(),
    'surviving_declarations': survivingDeclarations
        .map((d) => d.toJson())
        .toList(),
  };

  String formatText() {
    final buf = StringBuffer()
      ..writeln(
        'File: $filePath ($totalLines lines, $declarationCount top-level declarations)',
      )
      ..writeln(
        'Graph Topology: LCOM4 = $lcom4Islands island(s), '
        '$sccCount SCC node(s), max DAG depth = $maxTopologicalDepth',
      )
      ..writeln();

    if (clusters.isEmpty) {
      buf.writeln(
        'No clean extraction cuts recommended (file is already cohesive or below target size).',
      );
      return buf.toString();
    }

    buf.writeln(
      '=== RECOMMENDED EXTRACTION PLAN '
      '(Reduces $filePath: $totalLines -> ~$estimatedRemainingLines lines, '
      '0 circular deps, 0 caller churn) ===',
    );
    for (var i = 0; i < clusters.length; i++) {
      clusters[i].writeText(buf, i + 1, filePath);
    }
    _writeSurviving(buf);
    return buf.toString();
  }

  void _writeSurviving(StringBuffer buf) {
    if (survivingDeclarations.isEmpty) return;
    buf
      ..writeln()
      ..writeln(
        'Surviving in $filePath (~$estimatedRemainingLines lines, '
        '${survivingDeclarations.length} declaration(s)):',
      );
    for (final d in survivingDeclarations) {
      final note = d.lineCount > targetLines
          ? ' [Note: single ${d.kind} exceeds target $targetLines lines — '
                'consider extracting cohesive methods into a helper or extension]'
          : '';
      buf.writeln(
        '  - ${d.kind} ${d.name} '
        '(L${d.startLine}-${d.endLine}, ${d.lineCount} lines)$note',
      );
    }
  }
}
