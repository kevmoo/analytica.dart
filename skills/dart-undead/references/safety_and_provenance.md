# Dart Undead: Deletion Safety Invariants & PR Provenance Reference

This reference accompanies [`SKILL.md`](../SKILL.md) and provides the full
deletion safety invariants (Invariants 1–8), suppression comment placement
rules, dynamic-entrypoint heuristics, pre-deletion verification protocol, and
the standardized Pull Request & Commit provenance template.

---

## 1. Critical Safety Guardrails & Deletion Invariants (Full Reference)

> [!CAUTION]
>
> **Audit Before Deleting**: Never delete declarations autonomously without
> reviewing safety invariants and verifying against the test suite.

### Invariant 1: Sealed Class Hierarchy Protection

Direct subtypes of live `sealed` classes (via `extends`, `implements`, `with`,
or `enum`) must **NEVER** be deleted, even if unreferenced elsewhere. Deleting a
sealed subtype breaks Dart 3 exhaustive pattern matching across all `switch`
expressions.

### Invariant 2: Co-Invoked Test Hazard Protection

When a test file invokes both live and dead declarations:

- **Isolated Dead Tests**: Test blocks referencing _only_ dead code can be
  safely pruned alongside the dead target.
- **Co-Invoked Test Hazard**: When a single test function or widget test
  exercises both live and dead code, **do not delete the test**. Refactor the
  test body to remove only the dead assertions.

### Invariant 3: Framework Entrypoints & Pragmas

Ensure framework-specific roots are not falsely classified as dead:

- **Build Runner**: Builder factories and generator entrypoints in `build.yaml`.
- **VM Entrypoints**: Declarations annotated with `@pragma('vm:entry-point')`.
- **JS Interop**: External JavaScript facades (`@JS()`). Pass
  `--ignore-external-bindings` if pruning libraries with public interop headers.

### Invariant 4: Custom Suppression Syntax & Placement Rules

To suppress intentional dead code or API placeholders without deleting:

- **Declaration Level**: `// undead:ignore` (directly above the declaration; see
  Placement Rules below).
- **File Level**: `// undead:ignore_for_file` (below the copyright header; see
  Placement Rules below).
- _(Note: The standard `// ignore: unreachable_from_main` is strictly for the
  built-in Dart analyzer lint rule; `pkg:undead` requires `// undead:ignore`)._

**Placement Rules** (violations fail `dart analyze --fatal-infos` or style
review):

- **File-level**: Insert `// undead:ignore_for_file` **below** any copyright /
  license header block and above the `library` directive or first `import`.
  Never place it on line 1 above the copyright notice.
- **Declaration-level**: Never insert `// undead:ignore` between an existing
  `// ignore: <lint>` comment and its declaration. The analyzer only honors an
  `// ignore:` comment on the line immediately preceding the declaration, so
  detaching it produces `unnecessary_ignore` plus the original diagnostic (e.g.
  `unreachable_from_main`). Place `// undead:ignore` **above** the `// ignore:`
  line:

  ```dart
  // undead:ignore
  // ignore: unreachable_from_main
  Future<void> runTests(List<String> args) async { ... }
  ```

### Invariant 5: Dynamic Invocation & Non-AST Reference Check

Static AST analysis (`pkg:undead`) only traces typed Dart import trees. It
cannot see declarations referenced through runtime meta-programming:

- Dynamic isolate spawners (`dart.runInIsolate`, `Isolate.spawnUri`)
- Code-generation string templates (`'''import "package:.../foo.dart";'''`)
- JS / WASM compilation targets and runtime asset bootstrap runners
- Build hooks and `build.yaml` references
- Framework extension hooks and plugin registries invoked by downstream runners
  rather than by in-package call sites

**Dynamic-Entrypoint Heuristics (Require Confirmation, Never Blind Delete):**

Treat a zero-reference finding as a _suspected_ runtime entrypoint, not dead
code, when it matches any of these patterns. Classify it as **KEEP** (protect
with `// undead:ignore`) unless the user explicitly confirms removal:

- **File names**: `*_run.dart`, `direct_run.dart`, `*_bootstrap.dart`,
  `*_listener.dart`, `*_hook.dart`, `*_plugin.dart`.
- **Declaration names**: `register*`, `initialize*`, `bootstrap*`, `plugin*`,
  `custom*`, `install*`, `configure*` (e.g. `registerReporter`).
- **Shape**: public top-level functions whose only parameters are callbacks or
  factories, accepting a string key (`registerX(String name, Factory f)`), or
  that spawn isolates / compile kernels / open ports.
- **Context**: packages consumed as frameworks (test runners, build systems,
  plugin hosts) where downstream packages are the real callers.

**The Pre-Deletion Check Protocol:**

1. Before deleting any candidate file or top-level declaration in `lib/src/`,
   perform a literal string search (`grep_search "<filename_or_symbol>"`) across
   the repository.
2. If text matches exist outside the target file itself, **inspect and
   understand the match context** before deleting:
   - **KEEP**: The match is an active runtime string template, dynamic isolate
     entrypoint, or compilation target. Protect it with `// undead:ignore`.
   - **PRUNE**: The match is merely a doc comment, obsolete README reference, or
     dead test fixture that should be deleted alongside the target.

### Invariant 6: Monorepo & External Entrypoint Protection

In multi-package workspaces where internal implementation libraries export
entrypoints consumed by sibling CLI wrappers or test runners:

- Include sibling packages and root integration test folders using
  `--extra-roots` or enable `--workspace-discovery`.
- If an unexported function is an intended external entrypoint, protect it with
  `// undead:ignore` (and `// ignore: unreachable_from_main` if analyzer lint is
  active, ordered per the Invariant 4 Placement Rules).

### Invariant 7: Cohesive Subsystem Pruning

When pruning dead code, avoid partial or purely cosmetic deletions that leave
larger unreferenced subsystems intact:

- Delete all verified unreferenced internal classes, functions, and files in
  `lib/src/` (e.g., unreferenced listener classes, unused event sinks, obsolete
  scaffold runners) in one cohesive pass.
- Remove orphaned imports, associated dead private helpers, and obsolete test
  fixtures concurrently.

### Invariant 8: Deletion Hygiene (Comments Travel With Declarations)

A deletion range must cover the **entire** declaration, including everything
attached above it, so that nothing is left orphaned:

- **Doc comments**: Remove the full preceding `///` block (and any `/** */`
  block). An orphaned block at file head (before `library` / `import`
  directives) triggers `dangling_library_doc_comments` under
  `dart analyze --fatal-infos`, but an orphan stranded **between surviving
  declarations produces no diagnostic at all** and silently re-attaches to the
  next declaration — only a diff review catches it.
- **Annotations and `// ignore:` comments**: Remove `@Deprecated(...)`,
  `@visibleForTesting`, and any `// ignore: <lint>` lines that belonged to the
  deleted declaration; a leftover `// ignore:` triggers `unnecessary_ignore`.
- **Ignore comments on surviving neighbors**: When deleting one of several
  adjacent declarations, do not leave two `// ignore:` lines stacked on the
  survivor (`unnecessary_ignore` / `duplicate_ignore`).
- **Blank lines**: Collapse the resulting double blank line so `dart format`
  reports no changes.

---

## 2. Pull Request & Commit Provenance Protocol

When staging pruned code and preparing a commit message or Pull Request:

1. **User Confirmation Gate**: In interactive sessions, explicitly prompt the
   user in chat or via `ask_question` before including a **Tool Provenance &
   Reproduction block**. In unattended workflows, output the summary to chat or
   step summaries rather than modifying commit bodies without confirmation.
2. **Standardized Provenance Block Format**:

````markdown
### 🤖 Tool Provenance & Reproduction

Dead code detection and reachability analysis performed with
[`undead`](https://pub.dev/packages/undead) (`v{version}`).

To reproduce or re-run this reachability audit locally:

```bash
{exact_command_line}
```
````

3. **Version Resolution**: Check `pubspec.lock` in the workspace or run
   `dart run undead@^0.1.2 --version` (or use the exact invoked version
   constraint, e.g. `undead@^0.1.1`).
