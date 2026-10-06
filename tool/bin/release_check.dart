/// Pre-release pin sync and pre-flight runner for workspace packages.
///
/// ```
/// dart run tool/bin/release_check.dart [--fix] [--package <name>] [--no-test]
/// ```
///
/// Reports, per `packages/*` package: the pubspec version, the latest released
/// version, and how many `dart run <pkg>…@^x.y.z` sites in `skills/`,
/// `AGENTS.md`, and `evals/*.json` drift from that release. With `--fix`,
/// rewrites drifted constraints in place. Finishes by running `dart test` in
/// `tool/` (the same gate CI runs via `validate_skills.yaml`) and prints the
/// annotated-tag command for every package that is at a release version.
library;

import 'dart:io';

import 'package:_analytica_tool/skill_pins.dart';
import 'package:args/args.dart';
import 'package:path/path.dart' as p;

void main(List<String> args) {
  final parser = ArgParser()
    ..addFlag(
      'fix',
      negatable: false,
      help: 'Rewrite drifted @^x.y.z pins to each package\'s latest release.',
    )
    ..addOption(
      'package',
      abbr: 'p',
      help: 'Restrict the report to one package (e.g. cognitive_complexity).',
    )
    ..addFlag(
      'test',
      defaultsTo: true,
      help: 'Run `dart test` in tool/ after validation.',
    )
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show usage.');

  final ArgResults results;
  try {
    results = parser.parse(args);
  } on FormatException catch (e) {
    stderr
      ..writeln(e.message)
      ..writeln(parser.usage);
    exitCode = 64;
    return;
  }
  if (results.flag('help')) {
    stdout
      ..writeln('Usage: dart run tool/bin/release_check.dart [options]')
      ..writeln(parser.usage);
    return;
  }

  exitCode = _run(
    fix: results.flag('fix'),
    onlyPackage: results.option('package'),
    runTests: results.flag('test'),
  );
}

int _run({
  required bool fix,
  required String? onlyPackage,
  required bool runTests,
}) {
  final repoRoot = findRepoRoot();
  final packages = loadWorkspacePackages(repoRoot);
  if (onlyPackage != null && !packages.containsKey(onlyPackage)) {
    stderr.writeln(
      'Unknown package "$onlyPackage". Known: ${packages.keys.join(', ')}',
    );
    return 64;
  }

  final driftBefore = _countDrift(repoRoot, packages);
  _printPackageTable(packages, driftBefore, onlyPackage);

  if (fix) {
    _applyFixes(repoRoot, packages);
  }

  final errors = _validateAll(repoRoot, packages);
  _reportValidation(errors, fix: fix);

  final testsOk = !runTests || _runToolTests(repoRoot);

  _printTagCommands(packages, onlyPackage);
  return errors.isEmpty && testsOk ? 0 : 1;
}

void _applyFixes(Directory repoRoot, Map<String, PackageReleaseInfo> packages) {
  final edits = rewritePins(repoRoot, packages);
  if (edits.isEmpty) {
    stdout.writeln('\n--fix: no drifted pins to rewrite.');
    return;
  }
  stdout.writeln('\n--fix: rewrote ${_sum(edits.values)} pin(s):');
  for (final entry in edits.entries) {
    stdout.writeln('  ${entry.key}: ${entry.value}');
  }
}

void _reportValidation(List<String> errors, {required bool fix}) {
  if (errors.isEmpty) {
    stdout.writeln('\nPin validation: OK');
    return;
  }
  stdout.writeln('\nPin validation: ${errors.length} error(s)');
  for (final e in errors) {
    stdout.writeln('  $e');
  }
  if (!fix && errors.any((e) => e.contains('does not match'))) {
    stdout.writeln('  Hint: re-run with --fix to rewrite drifted pins.');
  }
}

Map<String, int> _countDrift(
  Directory repoRoot,
  Map<String, PackageReleaseInfo> packages,
) {
  final drift = <String, int>{for (final k in packages.keys) k: 0};
  for (final file in listPinSourceFiles(repoRoot)) {
    final rel = p.relative(file.path, from: repoRoot.path);
    for (final site in scanPinSites(
      text: file.readAsStringSync(),
      sourcePath: rel,
    )) {
      final released = packages[site.packageName]?.latestReleasedVersion;
      if (released == null) continue;
      if (site.constraint != '^$released') {
        drift[site.packageName] = (drift[site.packageName] ?? 0) + 1;
      }
    }
  }
  return drift;
}

void _printPackageTable(
  Map<String, PackageReleaseInfo> packages,
  Map<String, int> drift,
  String? onlyPackage,
) {
  stdout.writeln('Workspace packages (${packages.length}):');
  final names = packages.keys.toList()..sort();
  for (final name in names) {
    if (onlyPackage != null && name != onlyPackage) continue;
    final pkg = packages[name]!;
    final state = pkg.isWip ? 'wip' : 'RELEASE';
    final released = pkg.latestReleasedVersion ?? '(never released)';
    final d = drift[name] ?? 0;
    final driftText = d == 0 ? 'pins aligned' : '$d drifted pin(s)';
    stdout.writeln(
      '  ${name.padRight(22)} ${pkg.pubspecVersion.padRight(12)} '
      '${state.padRight(8)} latest=${released.padRight(18)} $driftText',
    );
  }
}

List<String> _validateAll(
  Directory repoRoot,
  Map<String, PackageReleaseInfo> packages,
) => [
  for (final file in listPinSourceFiles(repoRoot))
    ...validateInvocationsInText(
      text: file.readAsStringSync(),
      sourcePath: p.relative(file.path, from: repoRoot.path),
      packages: packages,
      repoRoot: repoRoot,
    ),
];

bool _runToolTests(Directory repoRoot) {
  final toolDir = p.join(repoRoot.path, 'tool');
  stdout.writeln('\nRunning `dart test` in tool/ ...');
  final result = Process.runSync(Platform.resolvedExecutable, [
    'test',
    '--reporter=compact',
  ], workingDirectory: toolDir);
  stdout.write(result.stdout);
  stderr.write(result.stderr);
  final ok = result.exitCode == 0;
  stdout.writeln(ok ? 'tool/ tests: OK' : 'tool/ tests: FAILED');
  return ok;
}

void _printTagCommands(
  Map<String, PackageReleaseInfo> packages,
  String? onlyPackage,
) {
  final releasable = [
    for (final pkg in packages.values)
      if (!pkg.isWip && (onlyPackage == null || pkg.name == onlyPackage)) pkg,
  ]..sort((a, b) => a.name.compareTo(b.name));
  if (releasable.isEmpty) return;

  stdout
    ..writeln('\nPackages at a release version (tag after the PR merges):')
    ..writeln(
      '  Tags must be annotated (-m); the Publish workflow is tag-triggered.',
    );
  for (final pkg in releasable) {
    final tag = '${pkg.name}-v${pkg.pubspecVersion}';
    stdout.writeln(
      '  git tag -m "${pkg.name} ${pkg.pubspecVersion}" $tag '
      '\$(git rev-parse origin/main) && git push origin $tag',
    );
  }
}

int _sum(Iterable<int> values) => values.fold(0, (a, b) => a + b);
