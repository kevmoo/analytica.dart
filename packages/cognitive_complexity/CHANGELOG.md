## 0.4.0-wip

- **Breaking**: `ShallowFinding` gains five required constructor parameters:
  `effectiveParameterCount`, `statementCount`, `callerZone`,
  `inlinedCallerScoreIsolated`, and `headroomAfterInline`. Code that only reads
  findings from `ShallowAnalyzer` is unaffected.
- `shallow`: `MICRO_HELPER` now also fires for helpers with `<= 2` statements
  spanning up to 15 body lines, so formatter-wrapped one-liners no longer evade
  it. The reason text includes the statement count.
- `shallow`: `HIGH_ARITY` is evaluated against the effective parameter count,
  where record-typed parameters expand to their field count; the reason text
  reports both (`HIGH_ARITY(4 params, 6 effective)`).
- `shallow`: `CROSS_FILE_SINGLE_CALLER` is no longer reported for `lib/`
  declarations whose single caller lives in `bin/`, `test/`, `tool/`,
  `example/`, or `web/` (package layering, not shallow extraction). Other
  reasons still apply to such helpers.
- `shallow`: JSON findings gain `effective_parameter_count`, `statement_count`,
  `caller_zone`, `inlined_caller_score_isolated` (caller base score plus this
  helper's delta, independent of sibling simulation order), and
  `headroom_after_inline` (`max_caller_cc - inlined_caller_score`). Text output
  appends `[isolated B -> I, headroom H]` when sibling absorption made the
  cumulative score differ from the isolated one.

## 0.3.0

- **Breaking**: `ShallowFinding` gains two required constructor parameters,
  `callerBaseScore` and `callerCumulativeBefore`. Code that only reads findings
  from `ShallowAnalyzer` is unaffected; code constructing `ShallowFinding`
  directly must pass both.
- `shallow`: when several single-caller helpers share one caller, the caller's
  score was reported as a running cumulative total with no way to recover the
  caller's real static score. Each finding now reports `caller_base_score` (the
  caller's static score) alongside `caller_cumulative_before` (the simulated
  score after earlier `SAFE_INLINE` siblings were absorbed). `caller_score` is
  retained as an alias of `caller_cumulative_before`. Text output renders
  `Caller CC: 6 (base 3) -> 9 after inline (+3)` whenever the two differ.
- `cognitive_complexity`: with `--max-function-lines`, the text table and the
  `--git-diff` text table now include a `Lines` column, and every violation
  marker names its trigger, e.g. `[VIOLATION: score > 15]`,
  `[VIOLATION: lines > 60]`, `[VIOLATION: score > 15, lines > 60]`, or
  `[VIOLATION: increased]` under `--fail-on-increase`. Consumers matching the
  bare `[VIOLATION]` token on stdout should match the `[VIOLATION` prefix
  instead. JSON output is unchanged.

## 0.2.6

- Auto-discover default targets when no positional paths are given: Pub
  workspace members (`<member>/lib`), single-package `lib/`, or `packages/*/lib`
  / `pkgs/*/lib` monorepo layouts. The GitHub Action `targets` input now
  defaults to auto-discovery, so workspace and monorepo callers no longer need a
  hardcoded target list (#137).
- Order `--git-diff` delta tables by review significance in every format (step
  summary, PR comment, `text`, `json`): violations first, then new score
  descending, then delta descending, then location.
  `DeltaAnalyzer.computeDeltas` gains `failThreshold`, `maxFunctionLines`, and
  `failOnIncrease` parameters and the comparator is exposed as
  `compareBySignificance` (#53).

## 0.2.5

- Omit zero-complexity (`delta == 0`, `score == 0`) added and removed
  declarations from `--git-diff` Markdown, CLI, and JSON delta tables (unless
  they trigger `--max-function-lines`), add `DeltaSummary.countRemoved` (`🗑️`),
  and format added/removed `Score` cells as `_new_ -> **N**` and
  `N -> _deleted_`.
- Add `shallow` CLI (`dart run cognitive_complexity:shallow`) and
  `ShallowAnalyzer` (`ShallowReport`, `ShallowFinding`, `ShallowClassification`)
  to detect single-caller shallow helpers (`HIGH_ARITY`, `MICRO_HELPER`,
  `SIG_HEAVY`, `CROSS_FILE_SINGLE_CALLER`) and simulate exact nesting-aware
  caller Cognitive Complexity after re-inlining (`SAFE_INLINE`,
  `FLATTEN_AND_INLINE`, `LOAD_BEARING`).
- Enhance `DataFlowAnalyzer` and `DataFlowResult`
  (`cognitive_complexity:data_flow`) with nesting-aware complexity impact
  metrics (`enclosingScore`, `sliceScoreInPlace`, `sliceScoreAtRoot`,
  `estimatedEnclosingScoreAfter`) and `extractionWarnings` when a proposed slice
  requires `>= 5` input parameters or provides low complexity payoff.
- Add opt-in `--max-file-lines` and `--max-function-lines` CLI flags and GitHub
  Action inputs (`max-file-lines`, `max-function-lines`) with `--git-diff`
  pragmatic ratchet support (`FileLineMetric`, `FileLineDelta`). Disabled
  (`null`) by default to preserve full backward compatibility.
- Support `// cognitive_complexity:ignore` (per-declaration) and
  `// cognitive_complexity:ignore_for_file` (file-wide) suppression comment
  directives via `CommentDirectiveParser`.
- Add `file_split` CLI (`dart run cognitive_complexity:file_split`) and
  `FileSplitAnalyzer` (`analyzeFile` / `analyzeFiles`) to compute acyclic file
  decomposition cuts targeting coarse `<= 800`-line subsystems using Tarjan's
  SCC condensation, immediate dominator cone absorption, dynamic shared-tail
  diamond re-evaluation, one-shot sufficiency & surplus small-cut re-absorption,
  zero-crossing sibling cone coalescing, `static` method promotion and embedded
  string/asset literal (`>75%`) detection for oversized classes, multi-file and
  directory batch execution, `--[no-]use-parts` support, and zero-churn
  `export ... show` barrel generation.
- Skip writing the `--comment-output` file entirely when a run has zero
  violations and zero complexity increases, so the GitHub Action stays quiet on
  the PR thread instead of posting an all-zeroes summary comment. The full
  report still lands in `$GITHUB_STEP_SUMMARY`. A diff that only _improves_
  complexity now also stays quiet.
- Add `DeltaSummary.isClean()`, the predicate behind that decision.
- GitHub Action: when a previously reported PR gets clean, the existing sticky
  comment is **updated in place** to a resolved status (never deleted), and only
  a successful run is treated as clean, so a crashed scan can no longer mark
  stale findings resolved. `--comment-output` is only requested when the scanner
  runs in `github` format against a diff base.
- Support `--exclude` and `--[no-]ignore-generated` CLI options to configure
  file exclusion and generated code filtering via `PathFilter`.
- Add `pathFilter` parameter to `ComplexityAnalyzer` and `DeltaAnalyzer`.
- Remove noisy GitHub workflow `::warning` annotations on non-violating
  complexity increases, keeping inline annotations reserved for violations
  (`::error`) while full deltas remain tracked in step summaries and PR comment
  tables.
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
