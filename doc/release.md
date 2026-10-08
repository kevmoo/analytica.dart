# Releasing a Package

Every publishable package under `packages/` ships independently. The
[`Publish`](../.github/workflows/publish.yaml) workflow is **tag-triggered**
(`<package>-v<major>.<minor>.<patch>`); merging a release PR does not publish
anything by itself.

## Why this needs a runbook

`skills/**`, `AGENTS.md`, and `skills/*/evals/evals.json` pin every
`dart run <pkg>[:<exec>]@^x.y.z` invocation to the **latest released** version
of that package. `tool/test/skills_cli_invocations_test.dart` (run on CI by
`validate_skills.yaml`) fails the moment a package's `pubspec.yaml` drops its
`-wip` suffix unless every pin for that package is bumped in the same commit.
Generic pre-flight tooling that only formats/analyzes does not catch this.

## Steps

1. **Promote the version.** In `packages/<pkg>/pubspec.yaml` change
   `version: x.y.z-wip` to `version: x.y.z`, and in
   `packages/<pkg>/CHANGELOG.md` rename the `## x.y.z-wip` heading to
   `## x.y.z`. Some packages also keep a hand-maintained version constant
   (`dedupe`: `lib/src/version.dart`; `undead`: `lib/src/cli.dart`) that
   `test/version_test.dart` checks against `pubspec.yaml` — update it too.

2. **Sync the pins and run the gate.**

   ```bash
   dart run tool/bin/release_check.dart --fix
   ```

   This rewrites every drifted `@^…` pin for packages at a release version,
   re-validates, runs `dart test` in `tool/`, and prints the `gh release create`
   command for step 5. Review the rewritten files in `git diff` — the only
   expected churn is `@^old` → `@^new`.

3. **Update skill prose, if the release adds flags or output.** Edits to
   `skills/*/SKILL.md` that describe new CLI surface must land in this same PR
   (they are not allowed on `main` before the version is published, and the pins
   already force the PR to touch those files).

4. **Open the PR** as `release(<pkg>): <x.y.z>` and let CI go green. Run
   `kscripts pr-check` locally first if available.

5. **Create the GitHub Release.** After the squash lands on `main`, create a
   GitHub Release (using the command printed by `release_check.dart`, or the
   `Publish tag (post-merge)` link in the PR's `## Package publishing` bot
   comment):

   ```bash
   git fetch origin
   awk '/^## x\.y\.z$/{f=1;next}/^## /{if(f)exit}f' packages/<pkg>/CHANGELOG.md | \
     gh release create <pkg>-vx.y.z \
       --target $(git rev-parse origin/main) \
       --title "package:<pkg> vx.y.z" \
       --notes-file -
   ```

   Using `gh release create` (rather than pushing a bare `git tag`) atomically
   creates both the formatted GitHub Release entry and the remote tag that
   triggers [`Publish`](../.github/workflows/publish.yaml).

6. **Confirm publication.**

   ```bash
   curl -s https://pub.dev/api/packages/<pkg> | jq -r .latest.version
   ```

   The `Publish` workflow usually completes within a minute of the tag push.

## Checking state without changing anything

```bash
dart run tool/bin/release_check.dart --no-test            # all packages
dart run tool/bin/release_check.dart -p cognitive_complexity
```

Exit code `1` means at least one pin is drifted or `tool/` tests failed.
