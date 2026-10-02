import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class _PackageInfo {
  final String name;
  final String pubspecVersion;
  final String? latestReleasedVersion;
  final Set<String> executables;

  const _PackageInfo({
    required this.name,
    required this.pubspecVersion,
    required this.latestReleasedVersion,
    required this.executables,
  });
}

Directory _getRepoRoot() {
  var dir = Directory.current;
  while (!File(p.join(dir.path, 'pubspec.yaml')).existsSync() ||
      !Directory(p.join(dir.path, 'skills')).existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) {
      return Directory.current.path.endsWith('tool')
          ? Directory.current.parent
          : Directory.current;
    }
    dir = parent;
  }
  return dir;
}

Map<String, _PackageInfo> _loadWorkspacePackages(Directory repoRoot) {
  final packagesDir = Directory(p.join(repoRoot.path, 'packages'));
  final result = <String, _PackageInfo>{};

  for (final dir in packagesDir.listSync().whereType<Directory>()) {
    final pubspecFile = File(p.join(dir.path, 'pubspec.yaml'));
    final changelogFile = File(p.join(dir.path, 'CHANGELOG.md'));
    if (!pubspecFile.existsSync() || !changelogFile.existsSync()) continue;

    final name = p.basename(dir.path);
    final pubspecLines = pubspecFile.readAsLinesSync();
    final pubspecVersion = _parsePubspecVersion(pubspecLines, pubspecFile.path);
    final executables = _parsePubspecExecutables(pubspecLines);
    final latestReleasedVersion = pubspecVersion.endsWith('-wip')
        ? _parseLatestReleasedVersion(changelogFile.readAsLinesSync())
        : pubspecVersion;

    result[name] = _PackageInfo(
      name: name,
      pubspecVersion: pubspecVersion,
      latestReleasedVersion: latestReleasedVersion,
      executables: executables,
    );
  }
  return result;
}

String _parsePubspecVersion(List<String> lines, String path) {
  final versionRegex = RegExp(r'^version:\s*(\S+)');
  for (final line in lines) {
    final match = versionRegex.firstMatch(line);
    if (match != null) return match.group(1)!;
  }
  fail('Missing version: in $path');
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
      if (match != null) {
        executables.add(match.group(1)!);
      }
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

final _dartRunRegex = RegExp(
  r'\bdart[ \t]+run[ \t]+(?:--[a-z-]+[ \t]+)*'
  r'(analytica|cli_readme|cognitive_complexity|dedupe|undead)'
  r'(?::([a-z0-9_]+))?'
  r'(?:@([^\s`"\x27\)]+))?',
);

List<String> _validateInvocationsInText({
  required String text,
  required String sourcePath,
  required Map<String, _PackageInfo> packages,
  required Directory repoRoot,
}) {
  final errors = <String>[];

  for (final match in _dartRunRegex.allMatches(text)) {
    final lineNum = text.substring(0, match.start).split('\n').length;
    final pkgName = match.group(1)!;
    final execName = match.group(2) ?? pkgName;
    final constraint = match.group(3);
    final pkg = packages[pkgName];
    if (pkg == null) {
      errors.add('$sourcePath:$lineNum: Unknown package "$pkgName".');
      continue;
    }

    final binFile = File(
      p.join(repoRoot.path, 'packages', pkgName, 'bin', '$execName.dart'),
    );
    if (!pkg.executables.contains(execName)) {
      errors.add(
        '$sourcePath:$lineNum: Executable "$execName" is not declared under '
        'executables: in packages/$pkgName/pubspec.yaml '
        '(found: ${pkg.executables.join(", ")}).',
      );
    } else if (!binFile.existsSync()) {
      errors.add(
        '$sourcePath:$lineNum: Missing executable file '
        'packages/$pkgName/bin/$execName.dart.',
      );
    }

    final releasedVersion = pkg.latestReleasedVersion;
    if (releasedVersion == null) {
      errors.add(
        '$sourcePath:$lineNum: Package "$pkgName" has no released version '
        '(current: ${pkg.pubspecVersion}) and cannot be referenced in skills.',
      );
      continue;
    }

    final expectedConstraint = '^$releasedVersion';
    if (constraint == null) {
      errors.add(
        '$sourcePath:$lineNum: Missing version constraint on '
        '"${match.group(0)}". Expected "@$expectedConstraint".',
      );
    } else if (constraint != expectedConstraint) {
      errors.add(
        '$sourcePath:$lineNum: Version constraint "@$constraint" on '
        '"${match.group(0)}" does not match latest released version of '
        '$pkgName ("@$expectedConstraint").',
      );
    }
  }
  return errors;
}

void main() {
  group('Skills CLI invocation and version alignment', () {
    test('all dart run invocations in skills/ and AGENTS.md specify valid '
        'executables and align with latest released package versions', () {
      final repoRoot = _getRepoRoot();
      final packages = _loadWorkspacePackages(repoRoot);
      expect(
        packages.keys,
        containsAll(['cognitive_complexity', 'dedupe', 'undead']),
      );

      final skillsDir = Directory(p.join(repoRoot.path, 'skills'));
      final files = <File>[
        File(p.join(repoRoot.path, 'AGENTS.md')),
        ...skillsDir
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.md') || f.path.endsWith('.json')),
      ]..sort((a, b) => a.path.compareTo(b.path));

      var totalInvocations = 0;
      final allErrors = <String>[];
      for (final file in files) {
        final content = file.readAsStringSync();
        totalInvocations += _dartRunRegex.allMatches(content).length;
        final relPath = p.relative(file.path, from: repoRoot.path);
        allErrors.addAll(
          _validateInvocationsInText(
            text: content,
            sourcePath: relPath,
            packages: packages,
            repoRoot: repoRoot,
          ),
        );
      }

      expect(
        totalInvocations,
        greaterThanOrEqualTo(20),
        reason: 'Expected to validate at least 20 dart run invocations.',
      );
      expect(allErrors, isEmpty, reason: allErrors.join('\n'));
    });

    test('validator detects missing constraints, version drift, and unknown '
        'executables', () {
      final repoRoot = _getRepoRoot();
      final packages = _loadWorkspacePackages(repoRoot);
      final ccVersion = packages['cognitive_complexity']!.latestReleasedVersion;

      final errors = _validateInvocationsInText(
        text: [
          'dart run cognitive_complexity:file_split lib/foo.dart',
          'dart run cognitive_complexity@^0.1.0 lib/',
          'dart run cognitive_complexity:nonexistent_cli@^$ccVersion lib/',
        ].join('\n'),
        sourcePath: 'synthetic.md',
        packages: packages,
        repoRoot: repoRoot,
      );

      expect(errors, hasLength(3));
      expect(errors[0], contains('Missing version constraint'));
      expect(errors[1], contains('does not match latest released version'));
      expect(errors[2], contains('Executable "nonexistent_cli"'));
    });
  });
}
