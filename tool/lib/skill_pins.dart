/// Shared scanner and validator for `dart run <pkg>[:<exec>][@<constraint>]`
/// invocations in `skills/**`, `AGENTS.md`, and `evals/*.json`.
///
/// Used by `tool/test/skills_cli_invocations_test.dart` (CI gate) and
/// `tool/bin/release_check.dart` (pre-release pin sync).
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// Release metadata for one workspace package under `packages/`.
class PackageReleaseInfo {
  final String name;
  final String pubspecVersion;

  /// Latest non-`-wip` version: the pubspec version when it is itself a
  /// release, otherwise the newest non-`-wip` `## x.y.z` heading in
  /// `CHANGELOG.md`. `null` when the package has never been released.
  final String? latestReleasedVersion;
  final Set<String> executables;

  const PackageReleaseInfo({
    required this.name,
    required this.pubspecVersion,
    required this.latestReleasedVersion,
    required this.executables,
  });

  bool get isWip => pubspecVersion.endsWith('-wip');
}

/// A single `dart run` invocation found in a documentation or eval file.
class PinSite {
  final String sourcePath;
  final int line;
  final String packageName;
  final String executable;
  final String? constraint;
  final String matchedText;

  const PinSite({
    required this.sourcePath,
    required this.line,
    required this.packageName,
    required this.executable,
    required this.constraint,
    required this.matchedText,
  });
}

/// Matches `dart run [--flag ...] <pkg>[:<exec>][@<constraint>]` for every
/// publishable workspace package.
final dartRunInvocationRegex = RegExp(
  r'\bdart[ \t]+run[ \t]+(?:--[a-z-]+[ \t]+)*'
  r'(analytica|cli_readme|cognitive_complexity|dedupe|undead)'
  r'(?::([a-z0-9_]+))?'
  r'(?:@([^\s`"\x27\)]+))?',
);

/// Walks up from [start] (default: `Directory.current`) to the workspace root
/// containing both `pubspec.yaml` and `skills/`.
Directory findRepoRoot([Directory? start]) {
  var dir = start ?? Directory.current;
  while (!File(p.join(dir.path, 'pubspec.yaml')).existsSync() ||
      !Directory(p.join(dir.path, 'skills')).existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) {
      final cwd = start ?? Directory.current;
      return cwd.path.endsWith('tool') ? cwd.parent : cwd;
    }
    dir = parent;
  }
  return dir;
}

/// Loads release metadata for every `packages/*` directory that has both a
/// `pubspec.yaml` and a `CHANGELOG.md`.
Map<String, PackageReleaseInfo> loadWorkspacePackages(Directory repoRoot) {
  final packagesDir = Directory(p.join(repoRoot.path, 'packages'));
  final result = <String, PackageReleaseInfo>{};

  for (final dir in packagesDir.listSync().whereType<Directory>()) {
    final pubspecFile = File(p.join(dir.path, 'pubspec.yaml'));
    final changelogFile = File(p.join(dir.path, 'CHANGELOG.md'));
    if (!pubspecFile.existsSync() || !changelogFile.existsSync()) continue;

    final name = p.basename(dir.path);
    final pubspecLines = pubspecFile.readAsLinesSync();
    final pubspecVersion = _parsePubspecVersion(pubspecLines, pubspecFile.path);
    final isWip = pubspecVersion.endsWith('-wip');

    result[name] = PackageReleaseInfo(
      name: name,
      pubspecVersion: pubspecVersion,
      latestReleasedVersion: isWip
          ? _parseLatestReleasedVersion(changelogFile.readAsLinesSync())
          : pubspecVersion,
      executables: _parsePubspecExecutables(pubspecLines),
    );
  }
  return result;
}

/// Returns `AGENTS.md` plus every `.md` / `.json` file under `skills/`, sorted
/// by path.
List<File> listPinSourceFiles(Directory repoRoot) {
  final skillsDir = Directory(p.join(repoRoot.path, 'skills'));
  return <File>[
    File(p.join(repoRoot.path, 'AGENTS.md')),
    ...skillsDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.md') || f.path.endsWith('.json')),
  ]..sort((a, b) => a.path.compareTo(b.path));
}

/// Extracts every invocation in [text].
List<PinSite> scanPinSites({required String text, required String sourcePath}) {
  return [
    for (final match in dartRunInvocationRegex.allMatches(text))
      PinSite(
        sourcePath: sourcePath,
        line: text.substring(0, match.start).split('\n').length,
        packageName: match.group(1)!,
        executable: match.group(2) ?? match.group(1)!,
        constraint: match.group(3),
        matchedText: match.group(0)!,
      ),
  ];
}

/// Validates every invocation in [text] against [packages]: the executable
/// must be declared and exist on disk, and the constraint must be exactly
/// `^<latestReleasedVersion>`.
List<String> validateInvocationsInText({
  required String text,
  required String sourcePath,
  required Map<String, PackageReleaseInfo> packages,
  required Directory repoRoot,
}) {
  final errors = <String>[];

  for (final site in scanPinSites(text: text, sourcePath: sourcePath)) {
    final where = '${site.sourcePath}:${site.line}';
    final pkg = packages[site.packageName];
    if (pkg == null) {
      errors.add('$where: Unknown package "${site.packageName}".');
      continue;
    }

    final binFile = File(
      p.join(
        repoRoot.path,
        'packages',
        site.packageName,
        'bin',
        '${site.executable}.dart',
      ),
    );
    if (!pkg.executables.contains(site.executable)) {
      errors.add(
        '$where: Executable "${site.executable}" is not declared under '
        'executables: in packages/${site.packageName}/pubspec.yaml '
        '(found: ${pkg.executables.join(", ")}).',
      );
    } else if (!binFile.existsSync()) {
      errors.add(
        '$where: Missing executable file '
        'packages/${site.packageName}/bin/${site.executable}.dart.',
      );
    }

    final releasedVersion = pkg.latestReleasedVersion;
    if (releasedVersion == null) {
      errors.add(
        '$where: Package "${site.packageName}" has no released version '
        '(current: ${pkg.pubspecVersion}) and cannot be referenced in skills.',
      );
      continue;
    }

    final expected = '^$releasedVersion';
    if (site.constraint == null) {
      errors.add(
        '$where: Missing version constraint on "${site.matchedText}". '
        'Expected "@$expected".',
      );
    } else if (site.constraint != expected) {
      errors.add(
        '$where: Version constraint "@${site.constraint}" on '
        '"${site.matchedText}" does not match latest released version of '
        '${site.packageName} ("@$expected").',
      );
    }
  }
  return errors;
}

/// Rewrites every drifted `@<constraint>` in [text] to
/// `@^<latestReleasedVersion>`. Invocations with no constraint and packages
/// with no release are left untouched (they remain validation errors).
({String text, int edits}) rewritePinsInText({
  required String text,
  required Map<String, PackageReleaseInfo> packages,
}) {
  var edits = 0;
  final rewritten = text.replaceAllMapped(dartRunInvocationRegex, (match) {
    final full = match.group(0)!;
    final constraint = match.group(3);
    final released = packages[match.group(1)!]?.latestReleasedVersion;
    if (constraint == null || released == null) return full;
    final expected = '^$released';
    if (constraint == expected) return full;
    edits++;
    return '${full.substring(0, full.length - constraint.length)}$expected';
  });
  return (text: rewritten, edits: edits);
}

/// Applies [rewritePinsInText] to every pin source file under [repoRoot].
/// Returns the number of edited sites keyed by repo-relative path.
Map<String, int> rewritePins(
  Directory repoRoot,
  Map<String, PackageReleaseInfo> packages,
) {
  final editsByFile = <String, int>{};
  for (final file in listPinSourceFiles(repoRoot)) {
    final original = file.readAsStringSync();
    final (:text, :edits) = rewritePinsInText(
      text: original,
      packages: packages,
    );
    if (edits == 0) continue;
    file.writeAsStringSync(text);
    editsByFile[p.relative(file.path, from: repoRoot.path)] = edits;
  }
  return editsByFile;
}

String _parsePubspecVersion(List<String> lines, String path) {
  final versionRegex = RegExp(r'^version:\s*(\S+)');
  for (final line in lines) {
    final match = versionRegex.firstMatch(line);
    if (match != null) return match.group(1)!;
  }
  throw StateError('Missing version: in $path');
}

Set<String> _parsePubspecExecutables(List<String> lines) {
  final executables = <String>{};
  var inExecutables = false;
  final entryRegex = RegExp(r'^  ([a-z0-9_]+):');

  for (final line in lines) {
    if (line.startsWith('executables:')) {
      inExecutables = true;
      continue;
    }
    if (inExecutables) {
      if (line.isNotEmpty && !line.startsWith(' ') && !line.startsWith('#')) {
        break;
      }
      final match = entryRegex.firstMatch(line);
      if (match != null) executables.add(match.group(1)!);
    }
  }
  return executables;
}

String? _parseLatestReleasedVersion(List<String> lines) {
  final headerRegex = RegExp(r'^##\s+(\d+\.\d+\.\d+(?:-\S+)?)');
  for (final line in lines) {
    final match = headerRegex.firstMatch(line);
    if (match == null) continue;
    final version = match.group(1)!;
    if (!version.endsWith('-wip')) return version;
  }
  return null;
}
