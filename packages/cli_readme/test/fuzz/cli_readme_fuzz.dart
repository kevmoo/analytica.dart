import 'dart:convert';
import 'dart:typed_data';

import 'package:cli_readme/cli_readme.dart';
import 'package:cli_readme/src/diff.dart';
import 'package:cli_readme/src/parser.dart';

void fuzzTarget(Uint8List data) {
  final markdown = utf8.decode(data, allowMalformed: true);
  final normalized = normalizeText(markdown);
  final fenced = formatCodeFence(content: normalized);
  generateDiff(expected: fenced, actual: markdown);

  for (final section in findMarkedSections(markdown)) {
    section.extractCodeFenceContent();
    replaceMarkedSection(
      markdown: markdown,
      section: section,
      newInnerContent: fenced,
    );
  }

  final wrapped =
      '<!-- CLI_README_START -->\n$markdown\n<!-- CLI_README_END -->';
  for (final section in findMarkedSections(wrapped)) {
    section.extractCodeFenceContent();
  }
}
