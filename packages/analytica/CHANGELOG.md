## 0.1.2-wip

- Power `PathFilter` with `package:glob`, so exclusion patterns support the
  full glob syntax including brace expansion (`**/*.{g,freezed}.dart`) and
  character classes (`**/*_[0-9].dart`).
- **Breaking:** `[`, `]`, `{` and `}` in an exclusion pattern are now glob
  metacharacters rather than literal characters. Escape them with
  `Glob.quote` to match them literally.
- **Breaking:** a malformed exclusion pattern now throws a `FormatException`
  naming the pattern, where it previously matched nothing silently.
- Match paths that escape the scanned tree (a leading `../`, as produced by
  `undead --extra-roots`) on their in-tree remainder, so a root-anchored
  pattern now applies to them.
- Pin exclusion matching to POSIX separators and case sensitivity on every
  platform.
- Add `PathFilter` in `package:analytica/analyzer.dart` for centralized path
  exclusion matching and generated Dart code filtering.
- Add `addPathFilterOptions` and `parsePathFilter` CLI utilities in
  `package:analytica/cli.dart`.
- Add `package:analytica/testing.dart` with `resolvePackageDirectory`,
  `resolvePackageFile`, `resolvePackageExecutable`, and `capturePrints` test
  helpers.

## 0.1.1

- Add `parseCommaSeparated` utility function in `package:analytica/cli.dart`.
- Fix `extractNodeName` and `_findFirstIdentifier` in
  `package:analytica/analyzer.dart` to ignore doc comment symbol references when
  ASTs lack element resolution (#80).
- Fix `WildcardPattern` in `package:analytica/analyzer.dart` to correctly
  support `**/` recursive directory glob matching.

## 0.1.0

- Initial release of core utilities, SDK discovery, Git integration, and CI
  reporting.
