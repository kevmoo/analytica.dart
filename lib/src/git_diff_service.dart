import 'dart:io';
import 'package:path/path.dart' as p;

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

  /// Finds Dart files modified between [baseRef] and HEAD using merge base.
  Future<List<String>> getModifiedDartFiles(
    String baseRef, {
    List<String> targetPaths = const [],
  }) async {
    final repoRoot = await getRepoRoot();
    final args = [
      'diff',
      '--name-only',
      '--diff-filter=ACMR',
      '$baseRef...HEAD',
    ];

    final res = await _runGit(args);
    if (res.exitCode != 0) {
      throw ArgumentError(
        'Git diff failed against base ref "$baseRef": '
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
      final norm = p.normalize(relPath);
      if (norm.contains('.dart_tool') ||
          norm.contains('.git') ||
          norm.contains('build${p.separator}')) {
        continue;
      }

      final absPath = p.join(repoRoot, relPath);
      if (targetPaths.isNotEmpty &&
          !targetPaths.any((t) => absPath.startsWith(p.absolute(t)))) {
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
}
