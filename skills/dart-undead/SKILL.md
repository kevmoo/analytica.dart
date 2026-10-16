---
name: dart-undead
description: >-
  Audits, triages, and safely remediates unreachable and dead declarations in
  Dart and Flutter codebases using deterministic reachability analysis
  (pkg:undead). Use when identifying unused top-level declarations, classes,
  functions, or dead test fixtures in libraries or closed applications. Don't
  use for single-file private variable lints (use standard analyzer lints), code
  formatting, or non-Dart/Flutter repositories.
license: Apache-2.0
key_features:
  - Automated whole-program reachability analysis
  - Dual analysis modes (library vs closed-app)
  - Co-invoked test hazard detection
  - Sealed class & framework entrypoint protection
  - Safe 2-stage triage & deletion protocol
  - Deletion hygiene & dynamic-entrypoint heuristics
  - Reproducible PR provenance reporting
---

# Dart Undead (`dart-undead`)

Deterministic reachability and dead/unused declaration analysis for Dart and
Flutter packages using `pkg:undead`.

---

## 1. When to Use This Skill

Use this skill when auditing codebase health, trimming dead weight from mature
packages, identifying orphaned internal abstractions, or cleaning up standalone
applications and CLI tools.

Unlike basic lexical lints (`unused_element`, `unused_field`) which only detect
unused file-private (`_`) identifiers, `undead` builds a whole-package
reachability graph from designated entrypoint roots down to all internal
declarations.

### Trigger Indicators

- **Orphaned Internal Utilities**: Functions, classes, or mixins under
  `lib/src/` unreachable from public API barrels or internal entrypoints.
- **Dead Application Features**: Unreachable views, controllers, or services in
  standalone CLI tools or Flutter apps.
- **Orphaned Test Fixtures**: Dead `Fake*` or `Mock*` fixtures left behind after
  features were refactored.
- **Pre-Release API Pruning**: Verifying whether newly introduced experimental
  helpers are actually wired up before public release.

### When NOT to Use

- **Single-File Private Lints**: Rely on standard `dart analyze` for simple
  local variable or private parameter lints.
- **Code Formatting or Lint Rules**: Use standard `dart format` or `dart fix`.
- **Non-Dart / Non-Flutter Projects**: Tool exclusively operates on Dart ASTs.

---

## 2. Automated Execution & Scope Resolution

Execute the official package CLI directly in the terminal to retrieve
reachability findings deterministically:

```bash
dart run undead@^0.1.2 [options] [target_path]
```

> [!NOTE]
>
> **Pre-Flight Package Resolution Gate**: `package:analyzer` requires
> `.dart_tool/package_config.json` to resolve `package:<name>/...` imports. If
> packages are unresolved, pass `--pub-get` to automatically run `dart pub get`
> or `flutter pub get`. If encountering `.dart_tool` atomic rename errors in
> sandboxed environments, pass `--no-precompile` (e.g.
> `dart run --no-precompile undead@^0.1.2`).

### Execution Modes

#### Mode 1: Library Package (Default / Open-World)

Preserves all non-`src` `lib/**` exports as public API roots. Analyzes whether
internal declarations (`lib/src/**`) are reachable from exported barrels or
tests:

```bash
# Markdown output for human review
dart run undead@^0.1.2

# Machine-readable JSON output for agent automation
dart run undead@^0.1.2 --format=json
```

#### Mode 2: Closed Application (`--mode=closed-app`)

Traces execution strictly from executable entrypoints (`bin/**`,
`lib/main.dart`, `lib/main_*.dart`). Treats unreferenced public declarations as
dead:

```bash
dart run undead@^0.1.2 --mode=closed-app
```

#### Mode 3: Example Code Handling (`--example-mode`)

Controls how code in `example/` is treated during reachability analysis:

- `demonstration` (Default): `example/` code is treated as a consumer root;
  example files are never suggested for deletion.
- `strict`: Analyzes reachability within `example/` itself.
- `skip`: Ignores `example/` completely during analysis.

```bash
dart run undead@^0.1.2 --example-mode=demonstration
```

### Common CLI Options Reference

| Option / Flag                     | Purpose                                                           | Default         |
| :-------------------------------- | :---------------------------------------------------------------- | :-------------- |
| `-m, --mode`                      | Analysis mode (`library` or `closed-app`).                        | `library`       |
| `-f, --format`                    | Output formatting (`markdown`, `json`, `github`).                 | `markdown`      |
| `--json-output=<path>`            | Write JSON report to file while preserving stdout.                | None            |
| `--example-mode`                  | Policy for `example/` (`demonstration`, `strict`, `skip`).        | `demonstration` |
| `--extra-roots=<dir1,dir2>`       | Comma-separated list of additional root/test dirs.                | `""`            |
| `--test-support-patterns`         | Comma-separated wildcards for test fixtures.                      | `Fake*,Mock*`   |
| `--ignore-name-patterns`          | Comma-separated wildcards for names to ignore.                    | `""`            |
| `--[no-]workspace-discovery`      | Discover consumer roots from sibling packages in workspace.       | `true`          |
| `--[no-]ignore-external-bindings` | Preserve unreferenced `@JS()` and FFI facades.                    | `false`         |
| `--[no-]suggest-private`          | Identify top-level declarations that can be made library-private. | `false`         |
| `--pub-get`                       | Auto-run `dart pub get` / `flutter pub get` if needed.            | `false`         |
| `--fail-on-undead`                | Exit with non-zero code (1) on findings (useful for CI).          | `false`         |

---

## 3. Critical Safety Guardrails & Deletion Invariants

> [!CAUTION]
>
> **Audit Before Deleting**: Never delete declarations autonomously without
> reviewing safety invariants and verifying against the test suite. See
> [`references/safety_and_provenance.md`](references/safety_and_provenance.md)
> for full suppression placement examples, dynamic-entrypoint heuristics, and
> the PR provenance template.

- **Invariant 1 — Sealed Class Hierarchy Protection**: Direct subtypes of live
  `sealed` classes (`extends`, `implements`, `with`, or `enum`) must **NEVER**
  be deleted, even if unreferenced elsewhere, to preserve exhaustive `switch`
  matching.
- **Invariant 2 — Co-Invoked Test Hazard Protection**: Test blocks referencing
  _only_ dead code can be pruned alongside the target. When a single test
  exercises both live and dead code, **do not delete the test**—remove only the
  dead assertions.
- **Invariant 3 — Framework Entrypoints & Pragmas**: Preserve `build.yaml`
  builders, `@pragma('vm:entry-point')` declarations, and `@JS()` facades (pass
  `--ignore-external-bindings` when pruning interop libraries).
- **Invariant 4 — Custom Suppression Syntax & Placement**: Use
  `// undead:ignore` (declaration-level) or `// undead:ignore_for_file`
  (file-level; Note: `// ignore: unreachable_from_main` is only for the Dart
  analyzer).
  - **File-level**: Place `// undead:ignore_for_file` **below** any copyright
    header and above `library` or the first `import` (never line 1 above
    copyright).
  - **Declaration-level**: Place `// undead:ignore` **above** any existing
    `// ignore: <lint>` line so the analyzer lint comment remains immediately
    adjacent to the declaration (avoiding `unnecessary_ignore`).
- **Invariant 5 — Dynamic Invocation & Non-AST Reference Check**: `pkg:undead`
  cannot see runtime meta-programming (`dart.runInIsolate`, `Isolate.spawnUri`,
  codegen string templates, JS/WASM bootstrap targets, `build.yaml` hooks, or
  downstream plugin registries).
  - **Dynamic-Entrypoint Heuristics (Classify as KEEP with `// undead:ignore`
    unless user confirms removal)**: Files matching `*_run.dart`,
    `direct_run.dart`, `*_bootstrap.dart`, `*_listener.dart`, `*_hook.dart`,
    `*_plugin.dart`; declarations named `register*`, `initialize*`,
    `bootstrap*`, `plugin*`, `custom*`, `install*`, `configure*`; callback/
    factory registrars (`registerX(String name, Factory f)`) or isolate/kernel/
    port spawners; or framework host packages.
  - **Pre-Deletion Check Protocol**: Run `grep_search "<filename_or_symbol>"`
    across the repo before deleting any `lib/src/` file or declaration. Inspect
    matches outside the target file: **KEEP** (protect with `// undead:ignore`)
    if used in runtime templates/isolates/targets; **PRUNE** alongside the
    target if only in doc comments, obsolete README references, or dead
    fixtures.
- **Invariant 6 — Monorepo & External Entrypoint Protection**: Use
  `--extra-roots` or `--workspace-discovery` for sibling CLI wrappers/runners,
  or protect intended external entrypoints with `// undead:ignore` (above
  `// ignore: unreachable_from_main`).
- **Invariant 7 — Cohesive Subsystem Pruning**: Delete all verified unreferenced
  internal classes, functions, and files in `lib/src/` in one cohesive pass
  along with orphaned imports, dead private helpers, and obsolete test fixtures.
- **Invariant 8 — Deletion Hygiene (Comments Travel With Declarations)**: Remove
  the full preceding `///` / `/** */` doc comment block (stranded blocks between
  surviving declarations silently re-attach without analyzer warnings, and
  file-head orphans trigger `dangling_library_doc_comments`), remove
  `@Deprecated` / `@visibleForTesting` / `// ignore:` lines belonging to the
  deleted declaration, avoid stacked `duplicate_ignore` on surviving neighbors,
  and collapse double blank lines.

---

## 4. The 2-Stage Triage & Confirmation Protocol

To prevent accidental deletions of public APIs or breaking downstream consumers,
follow this strict 2-stage workflow:

### Stage 1: Read-Only Audit & Reporting (Mandatory Stop)

Run `dart run undead@^0.1.2 --format=markdown` (or `--format=json`).

**Mandatory Persistent Artifact**: You MUST create a structured Markdown
artifact named `undead_triage_report.md` in
`<appDataDir>/brain/<conversation-id>/`. The artifact must include:

1. **Target Summary**: Package name, analysis mode (`library` vs `closed-app`),
   and total undead declarations detected.
2. **Actionable Findings Table**: Clickable file link, line number, declaration
   type (`class`, `function`, `method`, `variable`), and name. Must include code
   snippets.
3. **Safety Annotations**: Highlight any `sealed` subtypes, co-invoked test
   hazards, or public exports.

**Visible Chat Pre-Render**: You MUST render a high-level summary and a direct
clickable link to the triage report artifact in visible chat BEFORE invoking the
confirmation gate.

### Stage 2: Interactive User Confirmation Gate

**Anti-Blind-Modal Invariant**: Strictly FORBID calling `ask_question` in the
same step as an unrendered report without the report already existing on disk
and in chat. The question prompt in `ask_question` should explicitly reference
the generated triage artifact (e.g., "Based on the findings in
`[undead_triage_report.md](...)`...").

Pause execution and prompt the user (via interactive choice or chat) to select
the desired remediation scope:

1. **(Recommended) Prune All Verified Dead Subsystems & Files**: Concurrently
   delete all unreferenced internal classes, functions, and files in
   `lib/src/**` and isolated dead test files.
2. **Prune Application Entrypoints**: Target dead features in a closed app
   (`--mode=closed-app`).
3. **Suppress Findings**: Add `// undead:ignore` comments to intentional
   placeholders.
4. **Report-Only / Exit**: Acknowledge findings without code mutations.

> **Explicit Bypass & Non-Interactive Fallback**:
>
> - **Direct Directives**: Skip Stage 1 pause if given explicit remediation
>   instructions (e.g., "Prune dead code in `pkgs/foo` using `dart-undead`").
> - **Non-Interactive Execution**: In unattended or automated evaluation
>   workflows (e.g. `evalin` or subagents), proceed with Option 1 (Prune All
>   Verified Dead Subsystems) automatically after verifying baseline tests pass.

---

## 5. Pre & Post Deletion Verification Protocol

Always wrap code deletions in a strict test and analysis sandwich:

1. **Pre-Flight Baseline**:
   - Check `pubspec.yaml`: if `sdk: flutter` is declared, run `flutter test`;
     otherwise run `dart test`.
   - Confirm test suite is 100% green before touching code.
2. **Surgical Deletion**: Remove the flagged declaration together with its
   attached doc comments, annotations, and `// ignore:` lines (Invariant 8),
   plus any orphaned imports.
3. **Post-Flight Verification**:
   - Run `dart analyze --fatal-infos` (or `flutter analyze --fatal-infos`).
     Plain `dart analyze` exits 0 on `info` diagnostics, but many ecosystem CI
     pipelines (e.g. `dart-lang/test`) run with `--fatal-infos`, so
     `dangling_library_doc_comments`, `unnecessary_ignore`, `duplicate_ignore`,
     `unused_import`, and `directives_ordering` must all be resolved before
     committing.
   - Run `dart format --output=none --set-exit-if-changed .` to confirm no
     formatting drift from collapsed deletion ranges.
   - Run `flutter test` or `dart test` to confirm all remaining tests pass.
   - **Monorepo Downstream Gate**: In multi-package repositories, run tests
     across all dependent workspace packages and root integration tests before
     staging.
   - **Repository Policies**: If the repository enforces changelog tracking,
     update `CHANGELOG.md` alongside the change.
4. **Clean Diff Staging**: Inspect `git diff --stat` to ensure only intended
   declarations were removed, then read the `git diff` hunks themselves for
   stranded `///` doc comment, annotation, or `// ignore:` lines that the
   analyzer cannot flag (Invariant 8).

---

## 6. Pull Request & Commit Provenance Protocol

1. **User Confirmation Gate**: In interactive sessions, prompt the user in chat
   or via `ask_question` before appending the **Tool Provenance & Reproduction
   block** from
   [`references/safety_and_provenance.md`](references/safety_and_provenance.md#2-pull-request--commit-provenance-protocol)
   to the PR description or commit body. In unattended workflows, output the
   summary to chat or step summaries without modifying commit bodies.
2. **Version Resolution**: Check `pubspec.lock` in the workspace or run
   `dart run undead@^0.1.2 --version` (or use the exact invoked version
   constraint, e.g. `undead@^0.1.1`).
