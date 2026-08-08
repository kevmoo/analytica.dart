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

  VariableUsage copyWith({bool? isMutated, int? firstMutationLine}) {
    return VariableUsage(
      name: name,
      type: type,
      isMutated: isMutated ?? this.isMutated,
      declarationOffset: declarationOffset,
      declarationLine: declarationLine,
      firstMutationLine: firstMutationLine ?? this.firstMutationLine,
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'type': type,
    'isMutated': isMutated,
    'declarationLine': declarationLine,
    if (firstMutationLine != null) 'mutationLine': firstMutationLine,
  };
}

/// Identifies control flow jumps/escapes that affect functional extraction.
enum ControlFlowEscapeType { earlyReturn, loopBreak, loopContinue, yieldEscape }

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
  });

  Map<String, dynamic> toJson() => {
    'file': filePath,
    'startLine': startLine,
    'endLine': endLine,
    'enclosing': enclosingDeclaration,
    'isCleanlyExtractable': isCleanlyExtractable,
    'inputs': inputs.map((e) => e.toJson()).toList(),
    'mutations': mutations.map((e) => e.toJson()).toList(),
    'outputs': outputs.map((e) => e.toJson()).toList(),
    'escapes': escapes.map((e) => e.toJson()).toList(),
    'suggestedSignature': suggestedSignature,
  };
}
