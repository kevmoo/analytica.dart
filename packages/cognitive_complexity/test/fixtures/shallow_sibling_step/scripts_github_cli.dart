// Trimmed from kevmoo/scripts.dart `lib/src/pr_triage/github_cli.dart` at
// f97ecee.
//
// Expected: `_resolveLocalHeadSha` is SIBLING_STEP (sibling
// `_resolveLocalBranch` shares `resolve`+`Local`).
import 'dart:convert';

typedef CommandRunner =
    Future<String> Function(
      String executable,
      List<String> args, {
      String? workingDirectory,
    });

typedef PrContext = ({
  String owner,
  String repo,
  String prNumber,
  String workingDir,
});

typedef PrSyncStatus = ({
  String localBranch,
  String remoteBranch,
  String localHeadSha,
  String remoteHeadSha,
  bool isSynced,
});

Future<PrSyncStatus> fetchPrSyncStatus(
  PrContext context, {
  required CommandRunner runCommand,
}) async {
  final (rBranch, rHeadSha) = await _resolveRemoteBranchAndSha(
    context,
    runCommand: runCommand,
  );
  final localBranch = await _resolveLocalBranch(context.workingDir, runCommand);
  final localHeadSha = await _resolveLocalHeadSha(
    context.workingDir,
    runCommand,
  );

  return (
    localBranch: localBranch,
    remoteBranch: rBranch,
    localHeadSha: localHeadSha,
    remoteHeadSha: rHeadSha,
    isSynced: localBranch == rBranch && localHeadSha == rHeadSha,
  );
}

Future<(String, String)> _resolveRemoteBranchAndSha(
  PrContext context, {
  required CommandRunner runCommand,
}) async {
  try {
    final viewOutput = await runCommand('gh', [
      '-R',
      '${context.owner}/${context.repo}',
      'pr',
      'view',
      context.prNumber,
      '--json',
      'headRefName,headRefOid',
    ], workingDirectory: context.workingDir);
    final prData = jsonDecode(viewOutput) as Map<String, dynamic>;
    return (
      prData['headRefName']?.toString() ?? '',
      prData['headRefOid']?.toString() ?? '',
    );
  } catch (_) {
    return ('', '');
  }
}

Future<String> _resolveLocalBranch(
  String workingDir,
  CommandRunner runCommand,
) async {
  try {
    return (await runCommand('git', [
      'symbolic-ref',
      '--short',
      'HEAD',
    ], workingDirectory: workingDir)).trim();
  } catch (_) {
    try {
      return (await runCommand('git', [
        'rev-parse',
        '--abbrev-ref',
        'HEAD',
      ], workingDirectory: workingDir)).trim();
    } catch (_) {
      return '';
    }
  }
}

Future<String> _resolveLocalHeadSha(
  String workingDir,
  CommandRunner runCommand,
) async {
  try {
    return (await runCommand('git', [
      'rev-parse',
      'HEAD',
    ], workingDirectory: workingDir)).trim();
  } catch (_) {
    return '';
  }
}
