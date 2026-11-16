import 'package:analytica/git.dart';

void main() async {
  final diffs = await const GitDiffService().getParsedDiff('origin/main');

  for (final fileDiff in diffs) {
    print('Modified file: ${fileDiff.path}');
    print('Changed ranges: ${fileDiff.addedOrModifiedLineRanges}');
  }
}
