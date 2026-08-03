import 'dart:io';
import 'package:path/path.dart' as p;
import 'complexity_analyzer.dart';

/// A service wrapping Git commands for repository evaluation and diffing.
class GitDiffService {
  final String? _workingDirectory;

  const GitDiffService({this._workingDirectory});

  Future<ProcessResult> _runGit(List<String> args) =>
      Process.run('git', args, workingDirectory: _workingDirectory);

  /// Returns the absolute filesystem path of the target repository root.
  Future<String> getRepoRoot() async {
    final res = await _runGit(['rev-parse', '--show-toplevel']);
    if (res.exitCode != 0) {
      throw FileSystemException(
        'Not inside a valid git repository or git command failed.',
        _workingDirectory ?? Directory.current.path,
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

    final allChanged = output.split('\n').map((l) => l.trim()).toList();
    final results = <String>[];

    for (final relPath in allChanged) {
      if (relPath.isEmpty || p.extension(relPath) != '.dart') {
        continue;
      }
      if (isExcludedPath(relPath)) {
        continue;
      }

      final absPath = p.join(repoRoot, relPath);
      if (targetPaths.isNotEmpty) {
        final matches = targetPaths.any((t) {
          final absTarget = p.join(repoRoot, t);
          return p.isWithin(absTarget, absPath) || p.equals(absTarget, absPath);
        });
        if (!matches) {
          continue;
        }
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
}
