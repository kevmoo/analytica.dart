## 0.1.0-wip

- Initial release of `pkg:dedupe`:
  - Token-level and structural clone detection across Dart and Flutter codebases.
  - Polynomial rolling hash $k$-gram indexing and maximal clone extension.
  - Granular normalization filters (`--ignore-comments`, `--ignore-literals`, `--ignore-identifiers`).
  - Git diff integration and PR delta scanning (`--git-diff`, `--only-changed`).
  - Multi-format report generation: Markdown, JSON, GitHub Actions annotations/summaries, and terminal text.
  - Per-file duplication metrics, cluster classification, and estimated lines saved analysis.
  - CLI binary entrypoint (`bin/dedupe.dart`).
