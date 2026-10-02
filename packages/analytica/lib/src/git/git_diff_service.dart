import 'dart:io';

import 'package:path/path.dart' as p;

import '../analyzer/ast_helpers.dart';
import 'diff_parser.dart';
import 'models.dart';

/// A service wrapping Git commands for repository evaluation and diffing.
class GitDiffService {
  final String? workingDirectory;

  const GitDiffService({this.workingDirectory});

  Future<ProcessResult> _runGit(List<String> args) =>
      Process.run('git', args, workingDirectory: workingDirectory);

  /// Returns the absolute filesystem path of the target repository root.
  Future<String> getRepoRoot() async {
    final res = await _runGit(['rev-parse', '--show-toplevel']);
    if (res.exitCode != 0) {
      throw FileSystemException(
        'Not inside a valid git repository or git command failed.',
        workingDirectory ?? Directory.current.path,
      );
    }
    return (res.stdout as String).trim();
  }

  /// Resolves the common ancestor commit SHA between [baseRef] and HEAD.
  Future<String> getMergeBase(String baseRef) async {
    final res = await _runGit(['merge-base', baseRef, 'HEAD']);
    if (res.exitCode != 0) {
      throw ArgumentError(
        'Failed to resolve merge base for "$baseRef": '
        '${(res.stderr as String).trim()}',
      );
    }
    return (res.stdout as String).trim();
  }

  /// Finds Dart files modified between [baseCommit] and HEAD.
  Future<List<String>> getModifiedDartFiles(
    String baseCommit, {
    List<String> targetPaths = const [],
  }) async {
    final repoRoot = await getRepoRoot();
    final args = ['diff', '--name-only', '--diff-filter=ACMR', baseCommit];

    final res = await _runGit(args);
    if (res.exitCode != 0) {
      throw ArgumentError(
        'Git diff failed against base commit "$baseCommit": '
        '${(res.stderr as String).trim()}',
      );
    }

    final output = (res.stdout as String).trim();
    if (output.isEmpty) {
      return [];
    }

    final baseDir = workingDirectory ?? Directory.current.path;
    final resolvedTargets = [
      for (final t in targetPaths) ...[
        p.normalize(p.join(baseDir, t)),
        p.normalize(p.join(repoRoot, t)),
      ],
    ];
    final allChanged = output.split('\n').map((l) => l.trim()).toList();
    final results = <String>[];

    for (final relPath in allChanged) {
      if (relPath.isEmpty ||
          p.extension(relPath) != '.dart' ||
          isExcludedPath(relPath)) {
        continue;
      }

      final absPath = p.normalize(p.join(repoRoot, relPath));
      if (resolvedTargets.isNotEmpty &&
          !resolvedTargets.any(
            (t) => p.isWithin(t, absPath) || p.equals(t, absPath),
          )) {
        continue;
      }

      results.add(relPath);
    }

    return results;
  }

  /// Extracts the historical content of [relativePath] at [baseRef] from Git.
  Future<String> getHistoricalFileContent(
    String baseRef,
    String relativePath,
  ) async {
    final res = await _runGit(['show', '$baseRef:$relativePath']);
    if (res.exitCode != 0) {
      // File did not exist at base ref (Status A - newly added)
      return '';
    }
    return res.stdout as String;
  }

  /// Reads the current content of [relativePath] from disk.
  Future<String> getCurrentFileContent(String relativePath) async {
    final repoRoot = await getRepoRoot();
    final file = File(p.join(repoRoot, relativePath));
    if (!file.existsSync()) {
      return '';
    }
    return file.readAsString();
  }

  /// Returns the raw unified diff between [baseRef] and the working tree.
  Future<String> getUnifiedDiff(
    String baseRef, {
    List<String> targetPaths = const [],
  }) async {
    final args = ['diff', baseRef, '--', ...targetPaths];
    final res = await _runGit(args);
    if (res.exitCode != 0) {
      throw ArgumentError(
        'Git diff failed against base ref "$baseRef": '
        '${(res.stderr as String).trim()}',
      );
    }
    return res.stdout as String;
  }

  /// Returns the parsed [GitFileDiff] list between [baseRef] and the working
  /// tree.
  Future<List<GitFileDiff>> getParsedDiff(
    String baseRef, {
    List<String> targetPaths = const [],
  }) async {
    final rawDiff = await getUnifiedDiff(baseRef, targetPaths: targetPaths);
    return GitDiffParser.parse(rawDiff);
  }
}
