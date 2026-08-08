import 'dart:io';
import 'package:checks/checks.dart';
import 'package:cognitive_complexity/src/complexity/git_diff_service.dart';
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
      ).writeAsString('void initial() {}');

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
      ).writeAsString('void feature() {}');
      await runGit(['add', '.']);
      await runGit(['commit', '-m', 'Feature commit']);

      // Also modify main so they diverge
      await runGit(['checkout', 'main']);
      await File(
        p.join(repoPath, 'lib', 'main_only.dart'),
      ).writeAsString('void mainOnly() {}');
      await runGit(['add', '.']);
      await runGit(['commit', '-m', 'Main divergence commit']);

      // Merge base should be the commit before divergence
      final mergeBase = await git.getMergeBase('feat/test');
      check(mergeBase).isNotEmpty();

      // Verify that mergeBase has the feature.dart file missing
      // (since it was before divergence)
      final gitShow = await Process.run('git', [
        'show',
        '$mergeBase:lib/feature.dart',
      ], workingDirectory: repoPath);
      check(gitShow.exitCode).not((v) => v.equals(0));
    });

    test(
      'getModifiedDartFiles correctly lists added/modified Dart files under targetPath',
      () async {
        final git = GitDiffService(workingDirectory: repoPath);

        // Make a new branch and add a modified file inside and outside targets
        await runGit(['checkout', '-b', 'feat/changes']);

        await File(
          p.join(repoPath, 'lib', 'changed.dart'),
        ).writeAsString('void changed() {}');
        await File(
          p.join(repoPath, 'bin', 'ignored.dart'),
        ).create(recursive: true);
        await File(
          p.join(repoPath, 'bin', 'ignored.dart'),
        ).writeAsString('void ignored() {}');
        await File(
          p.join(repoPath, 'lib', 'ignored_extension.txt'),
        ).writeAsString('ignored text');

        await runGit(['add', '.']);
        await runGit(['commit', '-m', 'Changes commit']);

        // Get merge base commit SHA
        final mergeBase = await git.getMergeBase('main');

        // Check only files in 'lib' target
        final modifiedFiles = await git.getModifiedDartFiles(
          mergeBase,
          targetPaths: ['lib'],
        );

        check(modifiedFiles).deepEquals(['lib/changed.dart']);
      },
    );

    test(
      'getHistoricalFileContent reads content from specified commit SHA',
      () async {
        final git = GitDiffService(workingDirectory: repoPath);

        // Change file in a branch
        await runGit(['checkout', '-b', 'feat/edit']);
        await File(
          p.join(repoPath, 'lib', 'initial.dart'),
        ).writeAsString('void updated() {}');
        await runGit(['add', '.']);
        await runGit(['commit', '-m', 'Edit commit']);

        final mergeBase = await git.getMergeBase('main');

        // Historical content at mergeBase should be the initial version
        final oldContent = await git.getHistoricalFileContent(
          mergeBase,
          'lib/initial.dart',
        );
        check(oldContent.trim()).equals('void initial() {}');

        // Current content should be the updated version
        final currentContent = await git.getCurrentFileContent(
          'lib/initial.dart',
        );
        check(currentContent.trim()).equals('void updated() {}');
      },
    );
  });
}
