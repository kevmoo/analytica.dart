/// Data models for the resolved-AST file decomposition (`file_split`) advisor.
library;

import '../version.dart';

/// The 3-Tier File Decomposition classification (analogous to `data_flow`'s
/// 3-Tier Function Decomposition Rubric).
///
/// This is a closed set of constants, not an `enum`: new values may be added in
/// minor releases. `switch` statements and expressions over it must include a
/// default (`_`) arm.
final class SplitTier {
  const SplitTier._(this.name, this.label);

  /// Identifier of this value (`tier1CleanLibrary`, ...), used as the JSON
  /// `tier` value.
  final String name;

  /// Human-readable label used in text output and as JSON `tier_label`.
  final String label;

  /// Tier 1: Disjoint island (`LCOM4 >= 2`) or leaf-first DAG layer with
  /// 0 circular edges within the plan, 0 `sealed` boundary violations, and 0
  /// cross-cut `_private` widenings (all private helpers are single-dominator
  /// absorbed). Cycles inherited through copied imports are reported
  /// separately (`SplitCluster.warnings` / `SplitCluster.inheritedCycles`).
  static const tier1CleanLibrary = SplitTier._(
    'tier1CleanLibrary',
    'Tier 1: Clean Library Split (import + export show)',
  );

  /// Tier 2: One-way acyclic DAG cut that requires widening 1–3 shared
  /// `_private` helpers/members to `@internal` inside `lib/src/`.
  static const tier2InternalWidening = SplitTier._(
    'tier2InternalWidening',
    'Tier 2: Controlled @internal Widening Split',
  );

  /// Tier 3: Inseparable SCC cycle, massive `sealed` hierarchy, or dense
  /// cross-class `_private` member web (`>= 3` members) requiring `part` /
  /// `part of` (or interface inversion).
  static const tier3PartDirective = SplitTier._(
    'tier3PartDirective',
    'Tier 3: Library part / part of Split (Gated)',
  );

  /// All values, from cleanest to most invasive split.
  static const List<SplitTier> values = [
    tier1CleanLibrary,
    tier2InternalWidening,
    tier3PartDirective,
  ];

  @override
  String toString() => 'SplitTier.$name';
}

/// A single top-level declaration within an analyzed Dart source file.
class DeclarationUnit {
  final String name;
  final String kind;
  final int startLine;
  final int endLine;
  final bool isPublic;
  final bool isSealed;
  final int staticMethodCount;
  final int staticMethodLines;
  final int stringLiteralLines;

  /// Instance and static members (methods, getters, setters, fields) declared
  /// directly on this class; constructors are excluded. `0` for non-classes.
  final int memberCount;

  /// Members of [memberCount] annotated with `@override`.
  final int overrideMemberCount;

  /// `implements A, B` or `extends X` for classes that declare one; mixins
  /// (`with`) are not reported.
  final String? supertypeLabel;

  /// The representation type of an `extension type` (e.g. `String`), or
  /// `null` for every other kind.
  final String? representationType;
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
    this.staticMethodCount = 0,
    this.staticMethodLines = 0,
    this.stringLiteralLines = 0,
    this.memberCount = 0,
    this.overrideMemberCount = 0,
    this.supertypeLabel,
    this.representationType,
    required this.outgoingIntraFileRefs,
    required this.privateMemberAccessesByTarget,
    required this.requiredImportDirectives,
    required this.hardPinnedPeers,
  });

  int get lineCount => endLine >= startLine ? endLine - startLine + 1 : 0;

  /// True when at least half of the declared members are `@override`s of a
  /// declared supertype, i.e. the class size is bound by an interface surface
  /// rather than by promotable helpers.
  bool get isInterfaceBound =>
      supertypeLabel != null &&
      memberCount > 0 &&
      overrideMemberCount * 2 >= memberCount;

  Map<String, dynamic> toJson() => {
    'name': name,
    'kind': kind,
    'start_line': startLine,
    'end_line': endLine,
    'lines': lineCount,
    'is_public': isPublic,
    'is_sealed': isSealed,
    if (staticMethodCount > 0) 'static_method_count': staticMethodCount,
    if (staticMethodLines > 0) 'static_method_lines': staticMethodLines,
    if (stringLiteralLines > 0) 'string_literal_lines': stringLiteralLines,
    if (memberCount > 0) 'member_count': memberCount,
    if (overrideMemberCount > 0) 'override_member_count': overrideMemberCount,
    if (supertypeLabel != null) 'supertype': supertypeLabel,
    if (representationType != null) 'representation_type': representationType,
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
  final String? agentDirective;

  /// Informational notes, e.g. sibling types kept with this cut or left in
  /// the source file.
  final List<String> notes;

  /// Problems the cut inherits from the source file, e.g. a copied import
  /// that re-exports the source file (an inherited barrel cycle).
  final List<String> warnings;

  /// Informational: copied imports whose library already imports the source
  /// file (directly or through one re-export hop), so the cut carries over an
  /// import cycle the source file already has. `via` describes the link.
  final List<({String import, String via})> inheritedCycles;

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
    this.agentDirective,
    this.notes = const [],
    this.warnings = const [],
    this.inheritedCycles = const [],
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
    if (agentDirective != null) 'agent_directive': agentDirective,
    'declarations': declarations.map((d) => d.toJson()).toList(),
    'absorbed_private_helpers': absorbedPrivateHelpers,
    'private_top_levels_to_widen': privateTopLevelsToWiden,
    'private_members_to_widen': privateMembersToWiden,
    'required_imports': requiredImports,
    'exported_public_symbols': exportedPublicSymbols,
    'zero_churn_directive': zeroChurnExportDirective,
    if (notes.isNotEmpty) 'notes': notes,
    if (warnings.isNotEmpty) 'warnings': warnings,
    if (inheritedCycles.isNotEmpty)
      'inherited_cycles': [
        for (final c in inheritedCycles) {'import': c.import, 'via': c.via},
      ],
  };

  void _writeText(StringBuffer buf, int cutIndex, FileSplitReport report) {
    buf
      ..writeln()
      ..writeln('[Cut $cutIndex - ${tier.label}]')
      ..writeln('  Suggested File: $suggestedFileName (~$totalLines lines)')
      ..writeln('  Rationale: $rationale');
    if (agentDirective != null) {
      buf.writeln('  Agent Directive: $agentDirective');
    }
    buf.writeln('  Move Declarations (${declarations.length}):');
    report._writeDeclarationRows(buf, declarations, cluster: this);
    if (totalLines > report.targetLines &&
        declarations.length > 1 &&
        declarations.every((d) => d.lineCount <= report.targetLines)) {
      final note = tier == SplitTier.tier3PartDirective
          ? '[Note: cut exceeds target ${report.targetLines} lines across '
                '${declarations.length} mutually coupled declarations — '
                'breaking mutual private references is required to split '
                'further]'
          : '[Note: cut exceeds target ${report.targetLines} lines as a '
                'cohesive ${declarations.length}-declaration cluster — can '
                'be decomposed further once extracted]';
      buf.writeln('    $note');
    }
    for (final note in notes) {
      buf.writeln('    [Note: $note]');
    }
    _writeWidenings(buf);
    if (requiredImports.isNotEmpty) {
      buf.writeln('  Required Imports for $suggestedFileName:');
      for (final imp in requiredImports) {
        buf.writeln('    $imp');
      }
    }
    for (final warning in warnings) {
      buf.writeln('  Warning: $warning');
    }
    final bridge = zeroChurnExportDirective;
    if (bridge != null) {
      buf.writeln('  Zero-Churn Bridge for ${report.filePath}:');
      if (tier == SplitTier.tier3PartDirective) {
        buf.writeln('    + $bridge');
      } else {
        buf
          ..writeln("    + import '$suggestedFileName';")
          ..writeln('    + $bridge');
      }
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

/// Default instruction surfaced when `part` / `part of` is auto-recommended
/// (`useParts == null`) for an oversized class or tightly coupled SCC.
const kAskUserPartsPreferenceDirective =
    '(Non-interactive CLI note for AI agent — no stdin input required) '
    'Explicitly ASK the user whether they prefer '
    '`--use-parts` (`part` / `part of` directives to preserve private '
    '`_field` access on `this`) or '
    '`--no-use-parts` (extracting cohesive methods into a standalone helper '
    'class/library).';

/// Complete decomposition report for an analyzed Dart file.
class FileSplitReport {
  final String filePath;
  final int totalLines;
  final int targetLines;
  final bool? useParts;
  final int declarationCount;
  final int lcom4Islands;
  final int sccCount;
  final int maxTopologicalDepth;
  final List<SplitCluster> clusters;
  final List<DeclarationUnit> survivingDeclarations;
  final bool hasSurvivingCoupledScc;

  const FileSplitReport({
    required this.filePath,
    required this.totalLines,
    this.targetLines = 800,
    this.useParts,
    required this.declarationCount,
    required this.lcom4Islands,
    required this.sccCount,
    required this.maxTopologicalDepth,
    required this.clusters,
    required this.survivingDeclarations,
    this.hasSurvivingCoupledScc = false,
  });

  int get extractedLines => clusters.fold(0, (sum, c) => sum + c.totalLines);

  int get estimatedRemainingLines =>
      (totalLines - extractedLines).clamp(1, totalLines);

  /// Line count of the largest file produced by this plan (the maximum of
  /// [estimatedRemainingLines] and each extracted cluster's
  /// [SplitCluster.totalLines]).
  int get largestResultingFileLines => clusters.fold(
    estimatedRemainingLines,
    (maxLines, c) => c.totalLines > maxLines ? c.totalLines : maxLines,
  );

  /// Whether every file produced by this plan is at or below [targetLines].
  bool get meetsTarget => largestResultingFileLines <= targetLines;

  Map<String, dynamic> toJson() => {
    'schema_version': reportSchemaVersion,
    'file': filePath,
    'total_lines': totalLines,
    'target_lines': targetLines,
    'use_parts': useParts,
    'declaration_count': declarationCount,
    'lcom4_islands': lcom4Islands,
    'scc_count': sccCount,
    'max_topological_depth': maxTopologicalDepth,
    'extracted_lines': extractedLines,
    'estimated_remaining_lines': estimatedRemainingLines,
    'largest_resulting_file_lines': largestResultingFileLines,
    'meets_target': meetsTarget,
    'has_surviving_coupled_scc': hasSurvivingCoupledScc,
    'clusters': clusters.map((c) => c.toJson()).toList(),
    'surviving_declarations': survivingDeclarations
        .map((d) => d.toJson())
        .toList(),
  };

  String formatText() {
    final buf = StringBuffer()
      ..writeln(
        'File: $filePath '
        '($totalLines lines, $declarationCount top-level declarations)',
      )
      ..writeln(
        'Graph Topology: LCOM4 = $lcom4Islands island(s), '
        '$sccCount SCC node(s), max DAG depth = $maxTopologicalDepth',
      )
      ..writeln();

    if (clusters.isEmpty) {
      if (totalLines <= targetLines) {
        buf.writeln(
          'No clean extraction cuts recommended '
          '(file is already below target $targetLines lines).',
        );
      } else {
        buf.writeln(
          'No clean extraction cuts recommended '
          '(no extractable group fits; largest resulting file: '
          '$totalLines lines (target $targetLines not met)).',
        );
      }
      _writeSurviving(buf);
      return buf.toString();
    }

    final targetNote = meetsTarget ? '' : ' (target $targetLines not met)';
    // The header counts cycles between the plan's own files, which the
    // planner never creates; inherited cycles go on the Note line below.
    buf.writeln(
      '=== RECOMMENDED EXTRACTION PLAN '
      '(Reduces $filePath: $totalLines -> ~$estimatedRemainingLines lines, '
      'largest resulting file: ~$largestResultingFileLines lines$targetNote, '
      '0 circular deps, 0 caller churn) ===',
    );
    final barrel = clusters.fold(0, (s, c) => s + c.warnings.length);
    final carried = clusters.fold(0, (s, c) => s + c.inheritedCycles.length);
    if (barrel + carried > 0) {
      buf.writeln(
        'Note: $barrel inherited barrel cycle warning(s), $carried existing '
        'import cycle(s) carried over (informational)',
      );
    }
    for (var i = 0; i < clusters.length; i++) {
      clusters[i]._writeText(buf, i + 1, this);
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
    _writeDeclarationRows(buf, survivingDeclarations);
    if (estimatedRemainingLines > targetLines &&
        hasSurvivingCoupledScc &&
        survivingDeclarations.length > 1 &&
        survivingDeclarations.every((d) => d.lineCount <= targetLines)) {
      if (useParts == false) {
        buf.writeln(
          '  [Note: surviving declarations exceed target $targetLines lines '
          'across mutually coupled declarations — breaking mutual private '
          'references is required to split without `part` / `part of` '
          '(--no-use-parts active)]',
        );
      } else if (useParts == true) {
        buf.writeln(
          '  [Note: surviving declarations exceed target $targetLines lines '
          'across mutually coupled declarations — breaking mutual private '
          'references or splitting further with `part` / `part of` is '
          'required to reduce below target]',
        );
      } else {
        buf.writeln(
          '  [Note: surviving declarations exceed target $targetLines lines '
          'across mutually coupled declarations — breaking mutual private '
          'references is required to split into standalone libraries, or use '
          '`part` / `part of` (--use-parts) to split across part files. '
          'Agent Directive: $kAskUserPartsPreferenceDirective]',
        );
      }
    }
  }

  void _writeDeclarationRows(
    StringBuffer buf,
    List<DeclarationUnit> declarations, {
    SplitCluster? cluster,
  }) {
    final indent = cluster != null ? '    ' : '  ';
    final insideTier3Cut = cluster?.tier == SplitTier.tier3PartDirective;
    for (final d in declarations) {
      final absorbed =
          (cluster != null && cluster.absorbedPrivateHelpers.contains(d.name))
          ? ' [private — single-dominator absorbed]'
          : '';
      final note = d.lineCount > targetLines
          ? _oversizedDeclNote(d, insideTier3Cut: insideTier3Cut)
          : '';
      buf.writeln(
        '$indent- ${d.kind} ${d.name} '
        '(L${d.startLine}-${d.endLine}, ${d.lineCount} lines)$absorbed$note',
      );
    }
  }

  String _oversizedDeclNote(DeclarationUnit d, {required bool insideTier3Cut}) {
    final isEmbeddedAsset = d.stringLiteralLines >= (d.lineCount * 3) ~/ 4;
    if (isEmbeddedAsset) {
      return ' [Note: single ${d.kind} exceeds target $targetLines lines — '
          'contains ~${d.stringLiteralLines} lines of embedded string/asset '
          'literals (>75% of declaration); consider moving raw string or '
          'template assets to a separate file rather than splitting methods]';
    }
    final staticHint = (d.staticMethodCount == 0 || d.isInterfaceBound)
        ? ''
        : 'contains ${d.staticMethodCount} static method(s) '
              '(~${d.staticMethodLines} lines) that can be promoted to '
              'top-level functions to unlock standalone library extraction; ';
    final hints = '${_supertypeFact(d)}$staticHint';
    if (useParts == false) {
      return ' [Note: single ${d.kind} exceeds target $targetLines lines — '
          '${hints}consider extracting cohesive methods into a helper '
          'or extension (--no-use-parts active)]';
    }
    if (insideTier3Cut || useParts == true) {
      return ' [Note: single ${d.kind} exceeds target $targetLines lines — '
          '${hints}consider extracting cohesive methods into a helper or '
          'extension, or splitting further with `part` / `part of` to '
          'preserve private `_field` access]';
    }
    return ' [Note: single ${d.kind} exceeds target $targetLines lines — '
        '${hints}consider extracting cohesive methods into a helper or '
        'extension, or splitting with `part` / `part of` (--use-parts) to '
        'preserve private `_field` access. Agent Directive: '
        '$kAskUserPartsPreferenceDirective]';
  }

  /// `implements X (n/m members are @override)` when the class declares a
  /// supertype and overrides at least one member; flags interface binding.
  static String _supertypeFact(DeclarationUnit d) {
    final label = d.supertypeLabel;
    if (label == null || d.overrideMemberCount == 0) return '';
    final ratio =
        '${d.overrideMemberCount}/${d.memberCount} members are '
        '@override';
    if (d.isInterfaceBound) {
      return '$label ($ratio), so its size is bound by the interface '
          'surface; ';
    }
    return '$label ($ratio); ';
  }
}
