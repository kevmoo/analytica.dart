// Trimmed from kevmoo/scripts.dart `lib/src/gerrit_view/report_printer.dart`
// at f97ecee.
//
// Expected: `_printSection4ClosedAndAbandoned` is SIBLING_STEP (sections 1-3
// share `print`+`Section` and stay extracted).
class RemoteCL {
  final int number;
  final String subject;

  RemoteCL(this.number, this.subject);
}

class CommitDetails {
  final String sha;
  final String changeId;

  CommitDetails(this.sha, this.changeId);
}

class ClStatus {
  final String status;

  ClStatus(this.status);
}

typedef AlignmentResult = ({bool isAligned, String reason});

Map<String, String> getWorktreeBranches(String repoRoot) => {};

void _printSection1Aligned(
  Map<String, (RemoteCL, CommitDetails, AlignmentResult)> alignedBranches,
  String gerritHost,
  String gerritProject,
  String? currentBranch,
  Map<String, String> worktreeBranches,
) {
  if (alignedBranches.isEmpty) return;
  print('ACTIVE & ALIGNED LOCAL BRANCHES');
  for (final entry in alignedBranches.entries) {
    final branch = entry.key;
    final (remote, details, alignment) = entry.value;
    final marker = branch == currentBranch ? '*' : ' ';
    final worktree = worktreeBranches.containsKey(branch)
        ? ' (worktree ${worktreeBranches[branch]})'
        : '';
    print('$marker $branch$worktree');
    print('   https://$gerritHost/c/$gerritProject/+/${remote.number}');
    if (!alignment.isAligned) {
      print('   ${details.sha}: ${alignment.reason}');
    }
  }
}

void _printSection2RemoteOnly(
  Map<int, RemoteCL> remoteOnlyCLs,
  String gerritHost,
  String gerritProject,
) {
  if (remoteOnlyCLs.isEmpty) return;
  print('REMOTE-ONLY CLS (No local branch tracking)');
  for (final cl in remoteOnlyCLs.values) {
    print('  https://$gerritHost/c/$gerritProject/+/${cl.number}');
    print('   ${cl.subject}');
  }
}

void _printSection3ConflatedAndMismatched(
  Map<int, List<String>> conflatedBranches,
  Map<String, (RemoteCL, CommitDetails)> mismatchedChangeIdBranches,
  Map<int, RemoteCL> remoteCLs,
  Map<String, CommitDetails> branchDetails,
  String gerritHost,
  String gerritProject,
  String? currentBranch,
  String actualRepoRoot,
) {
  if (conflatedBranches.isEmpty && mismatchedChangeIdBranches.isEmpty) return;

  print('CONFLATED OR MISMATCHED BRANCHES in $actualRepoRoot');
  for (final MapEntry(key: clNumber, value: branches)
      in conflatedBranches.entries) {
    final remote = remoteCLs[clNumber];
    print('  CL $clNumber (${remote?.subject ?? 'unknown'}): $branches');
    for (final branch in branches) {
      final marker = branch == currentBranch ? '*' : ' ';
      print('   $marker $branch ${branchDetails[branch]?.sha ?? ''}');
    }
  }
  for (final MapEntry(key: branch, value: (remote, details))
      in mismatchedChangeIdBranches.entries) {
    print('  $branch: ${details.changeId} != CL ${remote.number}');
    print('   https://$gerritHost/c/$gerritProject/+/${remote.number}');
  }
}

void _printSection4ClosedAndAbandoned(
  Map<String, (int, CommitDetails, ClStatus)> closedClBranches,
  String gerritHost,
  String gerritProject,
  String actualRepoRoot,
  String defaultBranch,
  String? currentBranch,
  Map<String, String> worktreeBranches,
) {
  if (closedClBranches.isEmpty) return;

  print('CLOSED OR ABANDONED CLS WITH LOCAL BRANCHES in $actualRepoRoot');
  for (final MapEntry(key: branch, value: (clNumber, details, status))
      in closedClBranches.entries) {
    final marker = branch == currentBranch ? '*' : ' ';
    final worktree = worktreeBranches.containsKey(branch)
        ? ' (worktree ${worktreeBranches[branch]})'
        : '';
    print('$marker $branch$worktree [${status.status}] ${details.sha}');
    print('   https://$gerritHost/c/$gerritProject/+/$clNumber');
    print('   git checkout $defaultBranch && git branch -D $branch');
  }
}

void groupAndPrintReport({
  required String actualRepoRoot,
  required String defaultBranch,
  required String? currentBranch,
  required String gerritHost,
  required String gerritProject,
  required Map<String, (RemoteCL, CommitDetails, AlignmentResult)>
  alignedBranches,
  required Map<String, (int, CommitDetails, ClStatus)> closedClBranches,
  required Map<int, List<String>> conflatedBranches,
  required Map<String, (RemoteCL, CommitDetails)> mismatchedChangeIdBranches,
  required Map<int, RemoteCL> remoteOnlyCLs,
  required Map<int, RemoteCL> remoteCLs,
  required Map<String, CommitDetails> branchDetails,
}) {
  final worktreeBranches = getWorktreeBranches(actualRepoRoot);
  print('GERRIT WORKSPACE OVERVIEW\nRepository: $actualRepoRoot');

  _printSection1Aligned(
    alignedBranches,
    gerritHost,
    gerritProject,
    currentBranch,
    worktreeBranches,
  );
  _printSection2RemoteOnly(remoteOnlyCLs, gerritHost, gerritProject);
  _printSection3ConflatedAndMismatched(
    conflatedBranches,
    mismatchedChangeIdBranches,
    remoteCLs,
    branchDetails,
    gerritHost,
    gerritProject,
    currentBranch,
    actualRepoRoot,
  );
  _printSection4ClosedAndAbandoned(
    closedClBranches,
    gerritHost,
    gerritProject,
    actualRepoRoot,
    defaultBranch,
    currentBranch,
    worktreeBranches,
  );
}
