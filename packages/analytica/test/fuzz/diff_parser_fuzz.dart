import 'dart:convert';
import 'dart:typed_data';

import 'package:analytica/git.dart';

void fuzzTarget(Uint8List data) {
  final text = utf8.decode(data, allowMalformed: true);
  final diffs = GitDiffParser.parse(text);
  for (final diff in diffs) {
    diff.path;
    diff.addedOrModifiedLineRanges;
  }
}
