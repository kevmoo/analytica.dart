/// A deterministic semantic data-flow analysis library and CLI tool for Dart.
///
/// Computes reaching definitions (inputs), variable reassignments (mutations),
/// and liveness (outputs) for arbitrary code slices to enable safe, pure
/// "Extract Method" refactorings with Dart 3 Records.
library;

export 'src/data_flow/data_flow_analyzer.dart';
export 'src/data_flow/models.dart';
export 'src/data_flow/signature_synthesizer.dart';
