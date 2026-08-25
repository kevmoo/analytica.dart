## 0.2.5-wip

- Support `--exclude` and `--[no-]ignore-generated` CLI options to configure
  file exclusion and generated code filtering via `PathFilter`.
- Add `pathFilter` parameter to `ComplexityAnalyzer` and `DeltaAnalyzer`.
- Add `ensure_cli_readme_test.dart` to verify CLI `--help` documentation in
  `README.md`.
- Update GitHub Action documentation in `README.md` to reference modular
  subdirectory path (`packages/cognitive_complexity`) and add rendered Action
  Inputs Reference table.

## 0.2.4

- Fix `action.yml` monorepo auto-detection to evaluate default `lib` vs
  `packages` existence against the caller's `$GITHUB_WORKSPACE` instead of
  `$ACTION_PATH` (#76).
- Fix `action.yml` to run the scanner from the caller's `$GITHUB_WORKSPACE`
  rather than `$ACTION_PATH`, so relative `targets` and `--git-diff` resolve
  against the repository under audit when the action is used from another
  repository (#76).
- Add `--comment-output` and `--max-comment-rows` CLI options: with
  `--format=github`, write a second report capped to the most significant rows
  (violations, then increases, then additions) for posting as a PR comment,
  while the step summary keeps the full table (#49).
- Add `commentFile` and `maxCommentRows` parameters to `GitHubReporter`.
- Add `max-comment-rows` input to the GitHub Action (default `0` = unlimited) to
  keep sticky comments under GitHub's 65536-character body limit.
- Anchor GitHub annotations to the declaration line only, so they render under
  the function signature instead of after the closing brace (#55).
- Move package into pub workspace monorepo layout under
  `packages/cognitive_complexity`.
- Restore root `action.yml` and `skills/` structure for monorepo workspace.

## 0.2.3

- Replace table truncation notice with inline summary comment linking to step
  summary.

## 0.2.2

- Fix column wrapping and alignment formatting in markdown report tables.

## 0.2.1

- Add support for GitHub Actions step summary and comment outputs.

## 0.2.0

- Add Data-Flow analysis and helper extraction engine.

## 0.1.0

- Initial release of Cognitive Complexity calculation engine and CLI tool.
