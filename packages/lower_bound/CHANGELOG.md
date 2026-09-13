## 0.1.0-wip

- Skip writing the `--comment-output` file entirely when every validated package
  is clean, so the GitHub Action stays quiet on the PR thread instead of posting
  a zero-finding summary comment.
- GitHub Action: when a previously reported PR gets clean, the existing sticky
  comment is **updated in place** to a resolved status (never deleted), and only
  a successful run is treated as clean, so a crashed validation can no longer
  mark stale findings resolved.
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
