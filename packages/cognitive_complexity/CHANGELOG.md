## 2.0.0

- **Breaking:** `ShallowClassification` (which gains `siblingStep`, below),
  `SplitTier`, and `ControlFlowEscapeType` are now `final` classes with
  `static const` values instead of enums, so new values can be added in minor
  releases. There is no exhaustiveness guarantee: `switch` statements and
  expressions over them need a default (`_`) arm. `.index` is removed; `name`,
  `values`, `toString()`, `label` (where it existed), and `==` on the constants
  behave as before.
- `shallow`: a helper is now classified `SIBLING_STEP` when it is one step of a
  sequence: another callee of the same caller, declared in the same file and
  enclosing type, shares `>= 2` leading camelCase name tokens with it
  (`_readProcEnviron` / `_readProcCwd`), two or more share its leading verb
  (`_filterIgnored` / `_filterWorkspace` / `_filterOutdated`), or one shares its
  verb and arity (`_reportStaleShim` / `_reportUnknownSubcommand`). The
  verb-and-arity test needs both helpers to span more than one line. Calls on
  another receiver (`other.parse()`) are not siblings. `SIBLING_STEP` takes
  precedence over the score-based classifications, so a step that would cost the
  caller its headroom is still reported with its siblings. Like `ZERO_HEADROOM`,
  `SIBLING_STEP` helpers are not absorbed into the caller's cumulative score and
  do not count toward `--fail-on-safe-inline` or `--only-safe`, so the gate only
  gets looser. Adds `ShallowFinding.siblingSteps` (`sibling_steps` in JSON),
  `ShallowReport.siblingStepCount` (`sibling_step_count`), a header count, and a
  `Facts: siblings=[...] stay extracted` line.
- `file_split`: name cuts by their type cluster, keep sibling types together,
  and flag inherited import cycles (#182):
  - A cut whose public type declarations (class, enum, extension type, typedef,
    mixin; at least two) make up `>= 50%` of its naming lines is named
    `<stem>_models.dart` instead of after its longest declaration, unless a
    single type holds more than half of the type lines.
  - After planning, public leaf enums and same-representation extension types
    left in the source file are pulled into a cut that moves a sibling, when
    that stays within `--target-lines` and adds no boundary crossings. Siblings
    no cut can take get one `sibling type(s) … left in …` note.
  - A cut whose copied imports include a barrel that re-exports the source file
    (directly or through any one re-export hop) gets a warning suggesting moving
    the declarations the cut uses out of the barrel, and its rationale notes
    that "0 circular imports" holds only within the plan.
  - A copied import whose library merely imports the source file (an existing
    cycle the cut carries over) is informational: listed under
    `inherited_cycles` in JSON.
  - Text output adds one
    `Note: N inherited barrel cycle warning(s), M existing import cycle(s) carried over (informational)`
    line under the plan header; the header's `0 circular deps` covers the plan's
    own files.
  - New `SplitCluster.notes` / `SplitCluster.warnings` /
    `SplitCluster.inheritedCycles` (JSON `notes` / `warnings` /
    `inherited_cycles`, emitted when non-empty) and
    `DeclarationUnit.representationType` (JSON `representation_type`).
- JSON reports (`ShallowReport.toJson`, `FileSplitReport.toJson`,
  `DataFlowResult.toJson`, `DeltaSummary.toJson`, and `cognitive_complexity`
  `--max-file-lines --format json`) now include `'schema_version': 1` at the top
  level.

## 1.0.0

- **Breaking**: Pruned legacy backward-compatibility aliases, re-export shims,
  and internal helper leaks from the public library surface (`api.txt`):
  - Removed `ShallowFinding.callerScore` and the `'caller_score'` JSON alias
    (use `callerCumulativeBefore` / `'caller_cumulative_before'`).
  - Removed the `GitDiffService` and `isExcludedPath` re-exports from
    `package:cognitive_complexity/cognitive_complexity.dart`, and removed the
    `gitService` parameter from the public `DeltaAnalyzer` constructor (so
    `package:analytica` is no longer leaked in `api.txt`).
  - Removed dead or internal symbols (`GitHubReporter`, `SignatureSynthesizer`,
    `DataFlowAnalyzer.synthesizer`, `SplitCluster.writeText`,
    `VariableUsage.copyWith`, `VariableUsage.declarationOffset`,
    `DeltaStatus.label`, `FileSplitAnalyzer.analyzeResolvedUnit`,
    `compareBySignificance`, and `kAskUserPartsPreferenceDirective`) from the
    public entrypoints.
- **Breaking**: Standardized `data_flow --format json` (`DataFlowResult.toJson`
  and `VariableUsage.toJson`) keys to 1-to-1 `snake_case` field names
  (`start_line`, `end_line`, `enclosing_declaration`, `is_cleanly_extractable`,
  `enclosing_score`, `slice_score_in_place`, `slice_score_at_root`,
  `estimated_enclosing_score_after`, `extraction_warnings`,
  `suggested_signature`, `is_mutated`, `declaration_line`, and
  `first_mutation_line`, retaining `'file'`) to match `cognitive_complexity`,
  `file_split`, and `shallow`.
- `file_split`: Eliminated super-linear cone-merge overhead on dense
  many-declaration files, guarded against plans that extract 100% of top-level
  declarations, skips Tier-3 `part` fallback cuts that would leave less than 25%
  of the file behind, adds `largestResultingFileLines`, `meetsTarget`, and
  `hasSurvivingCoupledScc` (`largest_resulting_file_lines`, `meets_target`, and
  `has_surviving_coupled_scc` in `--format json`) to `FileSplitReport`, prints
  oversized-declaration notes on extracted cuts as well as surviving
  declarations, and merges top-level getter/setter pairs without losing spans or
  reference edges.
- `shallow`: Weights multi-arm `switch` expressions and `switch` statements by
  `max(0, armCount - 1)` when computing `statement_count` so lookup-table
  helpers with 3+ arms are no longer flagged as `MICRO_HELPER`, excludes
  mutually recursive call cycles from single-caller candidates, treats unnamed
  `extension on T` declarations as library-private (`<extension on T>`), and
  counts empty record `()` parameters as at least 1 effective parameter.
- `data_flow`: Preserves transitive generic type parameter bounds in synthesized
  signatures, marks `inputs` entries as mutated when reassigned via Dart 3
  pattern assignments (`(a, b) = ...`), detects collection `await for` elements,
  and ignores `await` / `yield` inside nested function closures.

## 0.4.0

- **Breaking**: `FunctionComplexity` gains a required `composition`
  (`ComplexityComposition` record: `branches`, `nesting`, `booleanOps`,
  `maxDepth`) and an `isTestEntrypoint` getter.
- `cognitive_complexity`: `--format json` declarations now carry `composition`
  (`branches`, `nesting`, `boolean_ops`, `max_depth`; the first three sum to
  `score`) and `is_test_entrypoint` (top-level `main` of a `_test.dart` file).
  New `--verbose` / `-v` flag adds a `Breakdown` column and a
  `[test entrypoint]` tag to the text table so a flat score-15 function is
  distinguishable from a five-deep pyramid. Scores are unchanged.
- **Breaking**: `ShallowFinding` also gains `sharedParamSignatureWith`,
  `sharedParamCount`, `paramsSubsetOfExistingType`, and `simulationIndex`.
- `shallow`: findings carry two descriptive parameter facts that point at a
  remedy other than inlining: `shared_param_signature_with` /
  `shared_param_count` (a same-file declaration sharing `>= 4` parameter names,
  suggesting a shared parameter record) and `params_subset_of_existing_type` (a
  same-file type whose instance fields cover `>= 4` of the parameters,
  preferring the enclosing type, suggesting that object be passed directly).
  Text output adds a `Facts:` line when either is present.
- `shallow`: report ordering is now classification, then caller groups ranked by
  their most significant finding (`HIGH_ARITY`/`SIG_HEAVY` before helpers that
  change the caller's score, before `+0` micro-predicates), then the caller,
  then simulation order (`simulation_index`). Within one caller the printed
  order matches the inline simulation, so a `Caller CC: N (base B)` line never
  precedes the sibling that produced `N`. Previously findings were ordered by
  estimated lines saved.
- **Breaking**: `ShallowFinding` gains five required constructor parameters:
  `effectiveParameterCount`, `statementCount`, `callerZone`,
  `inlinedCallerScoreIsolated`, and `headroomAfterInline`. Code that only reads
  findings from `ShallowAnalyzer` is unaffected.
- `shallow`: `MICRO_HELPER` now also fires for helpers with `<= 2` statements
  spanning up to 15 body lines, so formatter-wrapped one-liners no longer evade
  it. The reason text includes the statement count.
- `shallow`: `HIGH_ARITY` is evaluated against the effective parameter count,
  where record-typed parameters expand to their field count; the reason text
  reports both (`HIGH_ARITY(4 params, 6 effective)`). Only inline record type
  annotations expand, one level deep. A record `typedef` is a type declaration
  like a class and counts as one parameter, so a domain record passed through a
  helper is not reported as packing.
- `shallow`: `CROSS_FILE_SINGLE_CALLER` is no longer reported for `lib/`
  declarations whose single caller lives in `bin/`, `tool/`, `example/`, `web/`,
  or `benchmark/` (package layering, not shallow extraction). Other reasons
  still apply to such helpers. Helpers with a `test/` caller are, as before, not
  single-caller candidates at all.
- `shallow`: JSON findings gain `effective_parameter_count`, `statement_count`,
  `caller_zone`, `inlined_caller_score_isolated` (caller base score plus this
  helper's delta, independent of sibling simulation order), and
  `headroom_after_inline` (`max_caller_cc - inlined_caller_score`). Text output
  appends `[isolated B -> I, headroom H]` when sibling absorption made the
  cumulative score differ from the isolated one.
- `file_split`: the extraction planner now measures its remaining budget against
  the physical file length (imports, comments, and blank lines included) instead
  of the sum of declaration lines, matching the `estimated_remaining_lines` it
  reports. Files that were previously left over `--target-lines` with "No clean
  extraction cuts recommended" now receive cuts.
- `file_split`: suggested filenames derive from the largest public declaration
  in the cut rather than the first one in source order.
- `file_split`: a dominator-cone cut whose root declaration(s) merely bridge two
  or more otherwise-disconnected groups of `>= --min-cluster-lines` each is now
  emitted as one cut per group. Each root joins the group it has the most edges
  into and undersized groups follow their callers; the bundled cut is kept when
  the groups would import each other cyclically or would need more `@internal`
  widenings than the bundle. A root that bridges several groups only names its
  group when it holds at least a third of the group's lines. Rationale reads
  `Sub-component of the <root> cone`.
- `file_split`: the oversized-class note for a surviving declaration now reports
  its declared supertype and override ratio, e.g.
  `implements StorageAdapter (32/51 members are @override)`, and when at least
  half of the members are `@override` it states that the class size is bound by
  the interface surface instead of advising that static methods be promoted.
  `extends X` is reported the same way; mixins are not. `DeclarationUnit` gains
  `memberCount`, `overrideMemberCount`, `supertypeLabel`, and an
  `isInterfaceBound` getter (`member_count`, `override_member_count`,
  `supertype` in JSON).
- **Breaking**: `file_split --format json` always emits a JSON array with one
  report per analyzed file. Previously a single matching file produced a bare
  object and zero or several files produced an array.
- **Breaking**: `shallow` classifies a helper whose inlining lands the caller
  exactly on `--max-caller-cc` as `ZERO_HEADROOM` instead of `SAFE_INLINE`
  (`ShallowClassification.zeroHeadroom`, ranked between `SAFE_INLINE` and
  `FLATTEN_AND_INLINE`). `SAFE_INLINE` now requires the caller to stay strictly
  below the ceiling. `ZERO_HEADROOM` helpers are not absorbed into the caller's
  cumulative score for later siblings and do not count toward
  `--fail-on-safe-inline` or `--only-safe`. Reports gain `zero_headroom_count`
  and the text header lists the count.

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
