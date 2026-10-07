/// Immutable data models for data flow analysis.
library;

/// Represents the usage of a variable across data-flow bounds.
class VariableUsage {
  final String name;
  final String type;
  final bool isMutated;
  final int declarationOffset;
  final int declarationLine;
  final int? firstMutationLine;

  const VariableUsage({
    required this.name,
    required this.type,
    this.isMutated = false,
    required this.declarationOffset,
    required this.declarationLine,
    this.firstMutationLine,
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'type': type,
    'isMutated': isMutated,
    'declarationLine': declarationLine,
    if (firstMutationLine != null) 'mutationLine': firstMutationLine,
  };
}

/// Identifies control flow jumps/escapes that affect functional extraction.
enum ControlFlowEscapeType {
  earlyReturn,
  loopBreak,
  loopContinue,
  yieldEscape,
  rethrowEscape,
  closureEscape,
  constructorInitializerEscape,
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
    'file': filePath,
    'startLine': startLine,
    'endLine': endLine,
    'enclosing': enclosingDeclaration,
    'isCleanlyExtractable': isCleanlyExtractable,
    'enclosingScore': enclosingScore,
    'sliceScoreInPlace': sliceScoreInPlace,
    'extractedHelperScore': sliceScoreAtRoot,
    'estimatedEnclosingScoreAfter': estimatedEnclosingScoreAfter,
    'inputs': inputs.map((e) => e.toJson()).toList(),
    'mutations': mutations.map((e) => e.toJson()).toList(),
    'outputs': outputs.map((e) => e.toJson()).toList(),
    'escapes': escapes.map((e) => e.toJson()).toList(),
    if (extractionWarnings.isNotEmpty) 'extractionWarnings': extractionWarnings,
    'suggestedSignature': suggestedSignature,
  };
}
