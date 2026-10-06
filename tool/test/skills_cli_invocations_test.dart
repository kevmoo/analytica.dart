import 'dart:io';

import 'package:_analytica_tool/skill_pins.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('Skills CLI invocation and version alignment', () {
    test('all dart run invocations in skills/ and AGENTS.md specify valid '
        'executables and align with latest released package versions', () {
      final repoRoot = findRepoRoot();
      final packages = loadWorkspacePackages(repoRoot);
      expect(
        packages.keys,
        containsAll(['cognitive_complexity', 'dedupe', 'undead']),
      );

      var totalInvocations = 0;
      final allErrors = <String>[];
      for (final file in listPinSourceFiles(repoRoot)) {
        final content = file.readAsStringSync();
        final relPath = p.relative(file.path, from: repoRoot.path);
        totalInvocations += scanPinSites(
          text: content,
          sourcePath: relPath,
        ).length;
        allErrors.addAll(
          validateInvocationsInText(
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
      final repoRoot = findRepoRoot();
      final packages = loadWorkspacePackages(repoRoot);
      final ccVersion = packages['cognitive_complexity']!.latestReleasedVersion;

      final errors = validateInvocationsInText(
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

    test('rewritePinsInText bumps drifted constraints and leaves missing or '
        'unreleased ones alone', () {
      const packages = {
        'cognitive_complexity': PackageReleaseInfo(
          name: 'cognitive_complexity',
          pubspecVersion: '0.4.0-wip',
          latestReleasedVersion: '0.3.0',
          executables: {'cognitive_complexity', 'shallow'},
        ),
        'cli_readme': PackageReleaseInfo(
          name: 'cli_readme',
          pubspecVersion: '0.1.0-wip',
          latestReleasedVersion: null,
          executables: {'cli_readme'},
        ),
      };

      final (:text, :edits) = rewritePinsInText(
        text: [
          '`dart run cognitive_complexity@^0.2.6 --threshold 15 lib/`',
          'dart run cognitive_complexity:shallow@^0.3.0 lib/',
          'dart run cognitive_complexity:shallow lib/',
          '"dart run cli_readme@^0.0.1 --check"',
        ].join('\n'),
        packages: packages,
      );

      expect(edits, 1);
      expect(text.split('\n'), [
        '`dart run cognitive_complexity@^0.3.0 --threshold 15 lib/`',
        'dart run cognitive_complexity:shallow@^0.3.0 lib/',
        'dart run cognitive_complexity:shallow lib/',
        '"dart run cli_readme@^0.0.1 --check"',
      ]);
    });

    test('rewritePins round-trips the real repository with zero edits when '
        'pins are already aligned', () {
      final repoRoot = findRepoRoot();
      final packages = loadWorkspacePackages(repoRoot);
      for (final file in listPinSourceFiles(repoRoot)) {
        final (:text, :edits) = rewritePinsInText(
          text: file.readAsStringSync(),
          packages: packages,
        );
        expect(edits, 0, reason: file.path);
        expect(text, file.readAsStringSync(), reason: file.path);
      }
      expect(Directory(p.join(repoRoot.path, 'skills')).existsSync(), isTrue);
    });
  });
}
