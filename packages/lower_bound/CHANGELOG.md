## 0.1.0-wip

- Initial release of automated Dart dependency lower-bound validator and
  synthetic runtime isolation engine.
- Synthetic staging engine:
  - Isolates package `lib/` and `bin/` directories in temporary staging.
  - Strips `dev_dependencies` to prevent test-tooling floor poisoning.
  - Strips `resolution: workspace` so published dependencies resolve from
    `pub.dev`.
  - Sanitizes `analysis_options.yaml` (stripping dev linter includes).
  - Exact floor pinning via `dependency_overrides`.
  - Fallback for unpublished `-wip` monorepo siblings with path overrides and
    soft warnings.
- CLI tool (`bin/lower_bound.dart`) with support for `--targets`,
  `--pin`/`--no-pin`, `--sdk`, `--format=text|github|json`, `--comment-output`,
  `--max-comment-rows`, `--keep-temp`, and `--fail-on-error`.
- Composite GitHub Action (`action.yml`) supporting sticky PR comments, step
  summaries, error annotations, and workspace inputs.
