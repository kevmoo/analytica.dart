/// A deterministic, algorithmic Cognitive Complexity calculation library and
/// CLI tool for Dart and Flutter.
///
/// Supports modern Dart 3 features including switch expressions, pattern
/// guards (`when` clauses), and declarative collection control flow elements.
/// Also provides standard Git diff historical evaluation and GitHub Actions
/// diagnostic reporting capabilities.
library;

export 'src/cognitive_complexity_visitor.dart';
export 'src/complexity_analyzer.dart';
export 'src/delta_analyzer.dart';
export 'src/git_diff_service.dart';
export 'src/github_reporter.dart';
