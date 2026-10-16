# Acyclic File Decomposition (`file_split`), Shallow Helpers (`shallow`) & API Surface Reference

This reference accompanies [`SKILL.md`](../SKILL.md) and
[`refactoring_recipes.md`](refactoring_recipes.md), providing complete planner
mechanics, JSON/Dart schemas, library boundary rules, `api_summary` verification
gates, anti-metric-gaming guardrails, and the PR provenance template.

---

## 1. Anti-Metric-Gaming Guardrails & `data_flow` Schema Details

### Anti-Metric-Gaming Rules (Section 5.1 Reference)

- **Forbid Callback Trampolines & Closure-Wrapped Mutable Locals**: Never
  extract a helper that accepts a callback closure
  (`String Function(Object?) pp` or `bool Function() isAborted`) just to call
  back into a local recursive function or read a mutable local variable in the
  caller, and never slice a `try/catch` out of a retry loop with a `null`
  sentinel return. If a function relies on a nested recursive closure, promote
  the recursive closure itself (or a stateless private formatter/printer helper
  with `const` configuration fields) rather than passing recursion trampolines
  into extracted branch helpers.
- **Forbid `.catchError(...)` Metric Gaming in `async` Functions**: Never
  replace idiomatic `try { await ... } catch (e, s)` with `.catchError(...)`
  inside an `async` function solely to dodge `CatchClause` scoring, and never
  preserve or introduce zero-allocation fast-path regressions (e.g., allocating
  a new collection before an early-return fast path).
- **Forbid Multi-Pass Loop Splitting & `.expand` Metric Gaming**: Never split a
  single loop (or nested loop) into multiple sequential loops over the same
  collection or chain `.expand((c) => c)` / `.forEach(...)` solely to shed loop
  nesting depth.

### `data_flow` Complexity Impact Schema

When running
`dart run cognitive_complexity:data_flow@^2.0.1 <file>:<start>-<end>`, inspect
the complexity impact fields (`enclosing_score`, `slice_score_in_place`,
`slice_score_at_root`, `estimated_enclosing_score_after` in JSON;
`DataFlowResult.enclosingScore`, `sliceScoreInPlace`, `sliceScoreAtRoot`,
`estimatedEnclosingScoreAfter` in Dart) and honor any `extraction_warnings`
(high parameter count `>= 5` inputs, low complexity payoff, or shallow
signature-to-complexity ratio).

---

## 2. Stage 1 & Pattern G: Shallow Helper Audit (`shallow`, Advisory Only)

```bash
dart run cognitive_complexity:shallow@^2.0.1 lib/
dart run cognitive_complexity:shallow@^2.0.1 lib/ bin/
```

Without positional targets, `shallow` scans `lib/` in the current directory
(pass `lib/ bin/` or package paths explicitly for CLI tools and monorepos). Its
findings are prompts for judgment, never a queue to clear or a CI gate; apply
the Keep / Revert Heuristics in
[`SKILL.md`](../SKILL.md#53-keep--revert-heuristics) before acting on any of
them.

### Advisory Triage Table Format (Stage 1)

If you ran `cognitive_complexity:shallow`, list its findings (`SAFE_INLINE`,
`ZERO_HEADROOM`, `FLATTEN_AND_INLINE`, `LOAD_BEARING`) as advisory notes:

| Classification    | Helper Declaration       | Sole Caller                         | Helper Metrics               | Caller CC (`Before -> After`) | Suggested Review                                                                                                           |
| :---------------- | :----------------------- | :---------------------------------- | :--------------------------- | :---------------------------: | :------------------------------------------------------------------------------------------------------------------------- |
| **`SAFE_INLINE`** | `[_helper](file:///...)` | `[caller](file:///...)` (`depth=0`) | `params=6`, `LOC=18`, `CC=2` |   `0 (base 0) -> 2` (`+2`)    | **Review: consider re-inlining if** the helper is pure plumbing, has no same-shape siblings, and its name adds no meaning. |

### Reading Shallow Classifications & Structural Tags

The scanner identifies non-exported helpers with `FanIn == 1` and
`TestFanIn == 0` matching any of 4 structural tags (`HIGH_ARITY`,
`MICRO_HELPER`, `SIG_HEAVY`, `CROSS_FILE_SINGLE_CALLER`) and simulates the exact
caller Cognitive Complexity at the call-site nesting depth after re-inlining:

- **`SAFE_INLINE`** (`CallerCCAfter < 15`): Inlining is _possible_ without
  breaching the caller's budget. It is not a recommendation; apply the Section
  5.3 keep/revert heuristics in
  [`SKILL.md`](../SKILL.md#53-keep--revert-heuristics) first.
- **`ZERO_HEADROOM`** (`CallerCCAfter == 15`): Inlining would leave the caller
  no budget; leave extracted.
- **`HIGH_ARITY` / Parameter Record**: For sibling helpers sharing high-arity
  parameter clumps, a shared Dart 3 named record (or an existing domain/state
  object that already holds those values) usually beats inlining. `HIGH_ARITY`
  counts inline record parameters by field count, so packing arguments into an
  ad-hoc record is not an escape.
- **`Facts:` Remedies (`shared_param_signature_with`,
  `params_subset_of_existing_type` in JSON)**: Points at a Parameter Record or
  Existing State Object remedy instead of inlining.
- **`FLATTEN_AND_INLINE`** (`HelperCC <= 4`, `depth > 0`, `CallerCCAfter <= 22`,
  and no absorbed child helpers): Only relevant when the caller is itself a work
  item; flatten with Patterns A/B as part of that fix.
- **`LOAD_BEARING`** (`HelperCC >= 5` or `CallerCCAfter > 22`): Keep extracted,
  or narrow its parameter list if `HIGH_ARITY`.

---

## 3. Pattern F: Acyclic File Decomposition, Library Boundaries & `api_summary`

When a Dart file grows beyond `400` lines (enforceable via opt-in
`--max-file-lines 400` and `--max-function-lines 60` on `cognitive_complexity`),
run the deterministic intra-file dependency graph advisor:

```bash
dart run cognitive_complexity:file_split@^2.0.1 lib/src/large_file.dart --target-lines 300
```

### Planner Mechanics & JSON Output Schema

- `--target-lines` is a physical-line budget for the surviving file; the planner
  cuts disjoint islands first, then sub-cone leaf groups out of the dominant
  island, names each cut after its dominant public declaration, and skips Tier-3
  `part` fallback cuts that would leave `< 25%` of the pre-fallback file behind.
- The header reports `largest resulting file: N lines` (appending
  `(target M not met)` when `N > M`; `largest_resulting_file_lines` and
  `meets_target` in `--format json`, which always emits an array of one report
  per analyzed file).
- Oversized-declaration notes (`implements X (n/m members are @override)` /
  `extends X`, static-promotion hints, embedded-asset hints, and coupled-SCC vs.
  cohesive-island summaries) appear on both `Move Declarations` in extracted
  cuts and `Surviving Declarations` — when `>= 50%` of a class's members are
  `@override`, its size is bound by the interface surface, so narrow the
  interface or split behind a delegate rather than promoting statics.

### Load-Bearing Library Boundary Rule (`Tier 1` vs. `Tier 2`)

Prefer the boundary enforced by the Dart compiler (library privacy `_` and class
modifiers) over advisory lint annotations (`@internal`, which still leaks into
`api.txt` when attached to members of exported classes):

- **Tier 1 (Default — Standalone `lib/src/<topic>.dart`, CLI
  `[Cut N - Tier 1]`)**: Use when extracted helpers form a genuine sub-domain
  with narrow parameter lists (`<= 3` args), require **zero** access to private
  `_` members of the parent class/library, and cross **zero** library-scoped
  class modifier boundaries (`sealed`, `final`, `interface`, `base`, or private
  generative constructors `._()`). Re-export only intentional public symbols via
  explicit `export 'src/<topic>.dart' show ...;`—never unscoped
  `export 'src/...';`. (`[Cut N - Tier 2]` in `file_split` indicates a one-way
  acyclic cut that requires widening `1–3` internal `_` helpers to `@internal`
  inside `lib/src/`).
- **Tier 2 (`part` / `part of`, CLI `[Cut N - Tier 3]`)**: Use when splitting
  one cohesive domain where helpers share private `_` fields, private
  constructors (`._()`), `sealed`/`final`/`interface`/`base` modifiers, or
  internal invariants, OR when standalone `lib/src/` files would require
  widening visibility and risk leaking internal types via unscoped
  `export 'src/...';` directives.
- **Breaking Model/Enum Dispatch Back-Edges**: When data models/enums are fused
  into a single giant SCC with a parser/service class because an `enum` or model
  class defines a dispatch method calling the parser/service, move that dispatch
  method to an `extension` in the surviving file so the models extract cleanly
  into `<stem>_models.dart`.
- **Zero Uncalled Factories / Constructor Parity**: Whenever extracting
  `<stem>_models.dart` or adding a convenience factory (`Foo.fromBar(...)`),
  verify with `rg` that every newly added factory is called by the surviving
  file and never leave an inline constructor call with divergent field values
  alongside an unused factory.
- **Advisory Cut Naming**: `file_split` plans are advisory: the cuts are
  dependency-correct, but the suggested file name follows one declaration. Name
  each new file by what it actually holds (shared types belong in a
  `models`-style file), and update import sites directly instead of adding
  `export ... show` barrels.

### Mandatory `api_summary` Public API Surface Verification Gate

Whenever a complexity or file-split refactor extracts helpers across files or
touches `lib/` exports in a Dart package, verify that the public API surface did
not accidentally widen:

1. **Capture non-empty pre-refactor baseline** (without
   `.dart_tool/package_config.json`, `api_summary` silently exits `0` with `0`
   `package:` entries):
   ```bash
   test -f .dart_tool/package_config.json || dart pub get
   dart run api_summary@^1.1.0 > /tmp/api_before.txt && rg -q '^package:' /tmp/api_before.txt
   ```
2. **Capture post-refactor surface and verify zero unintended leaks**:
   ```bash
   dart run api_summary@^1.1.0 > /tmp/api_after.txt && rg -q '^package:' /tmp/api_after.txt
   diff -u /tmp/api_before.txt /tmp/api_after.txt
   ```
   If `api.txt` is tracked in the repository, also verify `git diff api.txt` is
   empty (or run `dart run api_summary@^1.1.0 --check`).

---

## 4. Pull Request & Commit Provenance Template

When confirmed by the user in interactive sessions, include this standardized
block in the PR description or commit body:

````markdown
### 🤖 Tool Provenance & Complexity Delta

This refactoring was guided by
[`cognitive_complexity`](https://pub.dev/packages/cognitive_complexity)
(`v{version}`).

| Target Declaration | Pre-Score | Post-Score | Operational Ceiling |
| :--- | :---: | :---: | :---: |
| `{declaration_name}` (`{file_path}`) | `{pre_score}` | `{post_score}` | `<={threshold}` |

To reproduce or re-evaluate cognitive complexity scores:

```bash
{exact_command_line}
```

```bash
dart run cognitive_complexity:data_flow@^2.0.1 {file}:{start_line}-{end_line}
```
````
