## 0.1.2-wip

- Add `package:analytica/testing.dart` with `resolvePackageDirectory`,
  `resolvePackageFile`, `resolvePackageExecutable`, and `capturePrints`
  test helpers.

## 0.1.1

- Add `parseCommaSeparated` utility function in `package:analytica/cli.dart`.
- Fix `extractNodeName` and `_findFirstIdentifier` in
  `package:analytica/analyzer.dart` to ignore doc comment symbol references
  when ASTs lack element resolution (#80).
- Fix `WildcardPattern` in `package:analytica/analyzer.dart` to correctly
  support `**/` recursive directory glob matching.

## 0.1.0

- Initial release of core utilities, SDK discovery, Git integration, and CI reporting.
