/// Immutable data models for data flow analysis.
library;

import '../schema_version.dart';

/// Represents the usage of a variable across data-flow bounds.
class VariableUsage {
  final String name;
  final String type;
  final bool isMutated;
  final int declarationLine;
  final int? firstMutationLine;

  const VariableUsage({
    required this.name,
    required this.type,
    this.isMutated = false,
    required this.declarationLine,
    this.firstMutationLine,
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'type': type,
    'is_mutated': isMutated,
    'declaration_line': declarationLine,
    if (firstMutationLine != null) 'first_mutation_line': firstMutationLine,
  };
}

/// Identifies control flow jumps/escapes that affect functional extraction.
///
/// This is a closed set of constants, not an `enum`: new values may be added in
/// minor releases. `switch` statements and expressions over it must include a
/// default (`_`) arm.
final class ControlFlowEscapeType {
  const ControlFlowEscapeType._(this.name);

  /// Identifier of this value (`earlyReturn`, ...), used as the JSON `type`
  /// value.
  final String name;

  static const earlyReturn = ControlFlowEscapeType._('earlyReturn');
  static const loopBreak = ControlFlowEscapeType._('loopBreak');
  static const loopContinue = ControlFlowEscapeType._('loopContinue');
  static const yieldEscape = ControlFlowEscapeType._('yieldEscape');
  static const rethrowEscape = ControlFlowEscapeType._('rethrowEscape');
  static const closureEscape = ControlFlowEscapeType._('closureEscape');
  static const constructorInitializerEscape = ControlFlowEscapeType._(
    'constructorInitializerEscape',
  );

  /// All values.
  static const List<ControlFlowEscapeType> values = [
    earlyReturn,
    loopBreak,
    loopContinue,
    yieldEscape,
    rethrowEscape,
    closureEscape,
    constructorInitializerEscape,
  ];

  @override
  String toString() => 'ControlFlowEscapeType.$name';
}

/// Represents a control flow escape found inside an extracted code block.
class ControlFlowEscape {
  final ControlFlowEscapeType type;
  final int line;
  final String description;

  const ControlFlowEscape({
    required this.type,
    required this.line,
    required this.description,
  });

  Map<String, dynamic> toJson() => {
    'type': type.name,
    'line': line,
    'description': description,
  };
}

/// The comprehensive result of data-flow extraction analysis.
class DataFlowResult {
  final String filePath;
  final int startLine;
  final int endLine;
  final String enclosingDeclaration;
  final List<VariableUsage> inputs;
  final List<VariableUsage> mutations;
  final List<VariableUsage> outputs;
  final List<ControlFlowEscape> escapes;
  final String suggestedSignature;
  final bool isCleanlyExtractable;
  final int enclosingScore;
  final int sliceScoreInPlace;
  final int sliceScoreAtRoot;
  final List<String> extractionWarnings;

  const DataFlowResult({
    required this.filePath,
    required this.startLine,
    required this.endLine,
    required this.enclosingDeclaration,
    required this.inputs,
    required this.mutations,
    required this.outputs,
    required this.escapes,
    required this.suggestedSignature,
    required this.isCleanlyExtractable,
    this.enclosingScore = 0,
    this.sliceScoreInPlace = 0,
    this.sliceScoreAtRoot = 0,
    this.extractionWarnings = const [],
  });

  /// Estimated Cognitive Complexity score of the enclosing declaration after
  /// extracting this slice.
  int get estimatedEnclosingScoreAfter =>
      (enclosingScore - sliceScoreInPlace).clamp(0, enclosingScore);

  Map<String, dynamic> toJson() => {
    'schema_version': reportSchemaVersion,
    'file': filePath,
    'start_line': startLine,
    'end_line': endLine,
    'enclosing_declaration': enclosingDeclaration,
    'is_cleanly_extractable': isCleanlyExtractable,
    'enclosing_score': enclosingScore,
    'slice_score_in_place': sliceScoreInPlace,
    'slice_score_at_root': sliceScoreAtRoot,
    'estimated_enclosing_score_after': estimatedEnclosingScoreAfter,
    'inputs': inputs.map((e) => e.toJson()).toList(),
    'mutations': mutations.map((e) => e.toJson()).toList(),
    'outputs': outputs.map((e) => e.toJson()).toList(),
    'escapes': escapes.map((e) => e.toJson()).toList(),
    if (extractionWarnings.isNotEmpty)
      'extraction_warnings': extractionWarnings,
    'suggested_signature': suggestedSignature,
  };
}
