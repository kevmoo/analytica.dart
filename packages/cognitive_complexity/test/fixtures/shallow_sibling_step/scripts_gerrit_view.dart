// Trimmed from kevmoo/scripts.dart `lib/src/gerrit_view.dart` at f97ecee.
//
// Expected: `_getDefaultBranch` stays SAFE_INLINE. It shares only the `get`
// verb and arity with `_getCurrentBranch`, and it is a one-line pass-through,
// so the verb+arity test is skipped.
import 'dart:io';

String sniffDefaultBranchSync(String repoPath) => 'main';

String _getDefaultBranch(String repoPath) => sniffDefaultBranchSync(repoPath);

String? _getCurrentBranch(String repoPath) {
  final result = Process.runSync('git', [
    'rev-parse',
    '--abbrev-ref',
    'HEAD',
  ], workingDirectory: repoPath);

  if (result.exitCode == 0) {
    final output = (result.stdout as String).trim();
    return output == 'HEAD' ? null : output;
  }
  return null;
}

String _resolveRepoInfo(String? gerritRepo) =>
    gerritRepo ?? Directory.current.path;

(String, String) _resolveGerritDetails(String actualRepoRoot) {
  final host = Platform.environment['GERRIT_HOST'];
  final project = Platform.environment['GERRIT_PROJECT'];
  if (host == null || project == null) {
    throw StateError('Not a Gerrit repository: $actualRepoRoot');
  }
  return (host, project);
}

Future<void> runGerritView({String? gerritRepo}) async {
  final actualRepoRoot = _resolveRepoInfo(gerritRepo);
  final defaultBranch = _getDefaultBranch(actualRepoRoot);
  final currentBranch = _getCurrentBranch(actualRepoRoot);
  final (gerritHost, gerritProject) = _resolveGerritDetails(actualRepoRoot);

  if (currentBranch == null) {
    print('Detached HEAD in $actualRepoRoot');
  } else if (currentBranch == defaultBranch) {
    print('On $defaultBranch');
  }
  print('https://$gerritHost/q/project:$gerritProject');
}
