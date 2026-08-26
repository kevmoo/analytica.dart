## 0.1.1-wip

- Adopt centralized `PathFilter` for `--exclude` and generated code filtering
  (`--[no-]ignore-generated`).
- Add `ensure_cli_readme_test.dart` to verify CLI `--help` documentation in
  `README.md`.
- Add `dart-dedupe` agent skill integration guide in `README.md`.

## 0.1.0

- Initial release of `pkg:dedupe`:
  - Token-level and structural clone detection across Dart and Flutter
    codebases.
  - Polynomial rolling hash k-gram indexing and maximal clone extension.
  - Granular normalization filters (`--ignore-comments`, `--ignore-literals`,
    `--ignore-identifiers`).
  - Persistent content-hashed disk caching (`--cache`, `--cache-dir`,
    `--clear-cache`).
  - Exact line-union overlapping clone cluster deduplication and net lines saved
    analysis.
  - Linear adjacent chaining and MinHash token verification for large-scale
    clone clusters (>50 instances).
  - Git diff integration and PR delta scanning (`--git-diff`, `--only-changed`).
  - Multi-format report generation: Markdown, JSON, GitHub Actions
    annotations/summaries, and terminal text.
  - Per-file duplication metrics, cluster classification, and estimated lines
    saved analysis.
  - Value-semantic, immutable report models (`CloneInstance`,
    `DuplicateCluster`, `DedupeReport`) with full JSON serialization.
  - CLI binary entrypoint (`bin/dedupe.dart`).
