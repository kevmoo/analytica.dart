import 'dart:io';

import 'package:analytica/git.dart';
import 'package:checks/checks.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

void main() {
  group('GitDiffService Integration', () {
    late String repoPath;

    Future<void> runGit(List<String> args) async {
      final res = await Process.run('git', args, workingDirectory: repoPath);
      if (res.exitCode != 0) {
        fail(
          'Git command failed: git ${args.join(" ")}\nStderr: ${res.stderr}',
        );
      }
    }

    setUp(() async {
      repoPath = p.join(d.sandbox, 'test_repo');
      await Directory(repoPath).create(recursive: true);

      // Initialize git repo
      await runGit(['init', '-b', 'main']);
      await runGit(['config', 'user.name', 'Tester']);
      await runGit(['config', 'user.email', 'test@example.com']);
      await runGit(['config', 'commit.gpgsign', 'false']);

      // Write initial commit
      await File(
        p.join(repoPath, 'lib', 'initial.dart'),
      ).create(recursive: true);
      await File(
        p.join(repoPath, 'lib', 'initial.dart'),
      ).writeAsString('void initial() {}\n');

      await runGit(['add', '.']);
      await runGit(['commit', '-m', 'Initial commit']);
    });

    test('getRepoRoot returns the resolved git root path', () async {
      final git = GitDiffService(workingDirectory: repoPath);
      final root = await git.getRepoRoot();
      check(p.canonicalize(root)).equals(p.canonicalize(repoPath));
    });

    test('getMergeBase finds common ancestor commit SHA', () async {
      final git = GitDiffService(workingDirectory: repoPath);

      // Create a branch and a commit
      await runGit(['checkout', '-b', 'feat/test']);
      await File(
        p.join(repoPath, 'lib', 'feature.dart'),
      ).writeAsString('void feature() {}\n');
      await runGit(['add', '.']);
      await runGit(['commit', '-m', 'Feature commit']);

      // Also modify main so they diverge
      await runGit(['checkout', 'main']);
      await File(
        p.join(repoPath, 'lib', 'main_only.dart'),
      ).writeAsString('void mainOnly() {}\n');
      await runGit(['add', '.']);
      await runGit(['commit', '-m', 'Main divergence commit']);

      final mergeBase = await git.getMergeBase('feat/test');
      check(mergeBase).isNotEmpty();
    });

    test(
      'getModifiedDartFiles correctly lists added/modified Dart files under targetPath',
      () async {
        final git = GitDiffService(workingDirectory: repoPath);

        await runGit(['checkout', '-b', 'feat/changes']);

        await File(
          p.join(repoPath, 'lib', 'changed.dart'),
        ).writeAsString('void changed() {}\n');
        await File(
          p.join(repoPath, 'bin', 'ignored.dart'),
        ).create(recursive: true);
        await File(
          p.join(repoPath, 'bin', 'ignored.dart'),
        ).writeAsString('void ignored() {}\n');
        await File(
          p.join(repoPath, 'lib', 'ignored_extension.txt'),
        ).writeAsString('ignored text\n');

        await runGit(['add', '.']);
        await runGit(['commit', '-m', 'Changes commit']);

        final mergeBase = await git.getMergeBase('main');

        final modifiedFiles = await git.getModifiedDartFiles(
          mergeBase,
          targetPaths: ['lib'],
        );

        check(modifiedFiles).deepEquals(['lib/changed.dart']);
      },
    );

    test('getModifiedDartFiles resolves relative targetPaths from '
        'subdirectory workingDirectory', () async {
      await runGit(['checkout', '-b', 'feat/subpkg']);
      final subpkgDir = p.join(repoPath, 'packages', 'pkg_a');
      await File(
        p.join(subpkgDir, 'lib', 'pkg_a.dart'),
      ).create(recursive: true);
      await File(
        p.join(subpkgDir, 'lib', 'pkg_a.dart'),
      ).writeAsString('void pkgA() {}\n');
      await File(
        p.join(repoPath, 'packages', 'pkg_b', 'lib', 'pkg_b.dart'),
      ).create(recursive: true);
      await File(
        p.join(repoPath, 'packages', 'pkg_b', 'lib', 'pkg_b.dart'),
      ).writeAsString('void pkgB() {}\n');

      await runGit(['add', '.']);
      await runGit(['commit', '-m', 'Subpkg commit']);

      final git = GitDiffService(workingDirectory: subpkgDir);
      final mergeBase = await git.getMergeBase('main');
      final modifiedFiles = await git.getModifiedDartFiles(
        mergeBase,
        targetPaths: ['lib'],
      );

      check(modifiedFiles).deepEquals(['packages/pkg_a/lib/pkg_a.dart']);
    });

    test(
      'getHistoricalFileContent and getCurrentFileContent read versions',
      () async {
        final git = GitDiffService(workingDirectory: repoPath);

        await runGit(['checkout', '-b', 'feat/edit']);
        await File(
          p.join(repoPath, 'lib', 'initial.dart'),
        ).writeAsString('void updated() {}\n');
        await runGit(['add', '.']);
        await runGit(['commit', '-m', 'Edit commit']);

        final mergeBase = await git.getMergeBase('main');

        final oldContent = await git.getHistoricalFileContent(
          mergeBase,
          'lib/initial.dart',
        );
        check(oldContent.trim()).equals('void initial() {}');

        final currentContent = await git.getCurrentFileContent(
          'lib/initial.dart',
        );
        check(currentContent.trim()).equals('void updated() {}');
      },
    );

    test('getUnifiedDiff and getParsedDiff return diff structures', () async {
      final git = GitDiffService(workingDirectory: repoPath);

      // Modify working tree file without committing
      await File(
        p.join(repoPath, 'lib', 'initial.dart'),
      ).writeAsString('void initial() {}\nvoid extra() {}\n');

      final rawDiff = await git.getUnifiedDiff('HEAD');
      check(rawDiff).contains('+void extra() {}');

      final parsed = await git.getParsedDiff('HEAD');
      check(parsed.length).equals(1);
      check(parsed.first.path).equals('lib/initial.dart');
      check(
        parsed.first.addedOrModifiedLineRanges,
      ).deepEquals([const LineRange(2, 2)]);
    });
  });
}
