/// A deterministic, algorithmic Cognitive Complexity calculation library and
/// CLI tool for Dart and Flutter.
///
/// Supports modern Dart 3 features including switch expressions, pattern
/// guards (`when` clauses), and declarative collection control flow elements.
/// Also provides Git diff historical evaluation, shallow single-caller helper
/// detection, and file-split decomposition planning.
library;

export 'src/complexity/complexity_analyzer.dart'
    show
        ComplexityAnalyzer,
        ComplexityComposition,
        FileLineMetric,
        FunctionComplexity,
        PathFilter;
export 'src/complexity/delta_analyzer.dart'
    show
        ComplexityDelta,
        DeltaAnalyzer,
        DeltaStatus,
        DeltaSummary,
        FileLineDelta;
export 'src/file_split/file_split_analyzer.dart' show FileSplitAnalyzer;
export 'src/file_split/models.dart'
    show DeclarationUnit, FileSplitReport, SplitCluster, SplitTier;
export 'src/shallow/models.dart'
    show ShallowClassification, ShallowFinding, ShallowReport;
export 'src/shallow/shallow_analyzer.dart' show ShallowAnalyzer;
