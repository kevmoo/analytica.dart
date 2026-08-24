import 'package:checks/checks.dart';
import 'package:cli_readme/cli_readme.dart';
import 'package:cli_readme/src/parser.dart';
import 'package:test/test.dart';

void main() {
  group('findMarkedSections', () {
    test('finds default untagged marker section', () {
      const markdown = '''
# My Tool

<!-- CLI_README_START -->
```console
\$ my_tool --help
Usage: my_tool
```
<!-- CLI_README_END -->

More content.
''';

      final sections = findMarkedSections(markdown);
      check(sections).length.equals(1);
      final section = sections.first;
      check(section.id).equals('');
      check(section.startMarker).equals('<!-- CLI_README_START -->');
      check(section.endMarker).equals('<!-- CLI_README_END -->');
      check(
        normalizeText(section.extractCodeFenceContent()!),
      ).equals('\$ my_tool --help\nUsage: my_tool');
    });

    test('finds multiple tagged marker sections', () {
      const markdown = '''
# Multi Tool

<!-- CLI_README_START client -->
```console
\$ client --help
```
<!-- CLI_README_END client -->

<!-- CLI_HELP_START server -->
```console
\$ server --help
```
<!-- CLI_HELP_END server -->
''';

      final sections = findMarkedSections(markdown);
      check(sections).length.equals(2);
      check(sections[0].id).equals('client');
      check(sections[1].id).equals('server');
    });
  });

  group('replaceMarkedSection', () {
    test('replaces inner content preserving surrounding text', () {
      const markdown = '''
# Title
<!-- CLI_README_START -->
OLD CONTENT
<!-- CLI_README_END -->
Footer
''';

      final sections = findMarkedSections(markdown);
      final updated = replaceMarkedSection(
        markdown: markdown,
        section: sections.first,
        newInnerContent: '```console\n\$ new_cmd --help\n```',
      );

      check(updated).contains('```console\n\$ new_cmd --help\n```');
      check(updated).contains('# Title');
      check(updated).contains('Footer');
      check(updated).not((it) => it.contains('OLD CONTENT'));
    });
  });
}
