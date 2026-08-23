import 'package:checks/checks.dart';
import 'package:lower_bound/src/github_actions.dart';
import 'package:test/test.dart';

void main() {
  group('GitHub Actions Helpers', () {
    test('emitGitHubError formats and escapes correctly', () {
      final sink = StringBuffer();
      emitGitHubError(
        'Compile error line 1\nCompile error line 2: with colons',
        file: 'lib/src/foo.dart',
        line: 10,
        title: 'Error: Title, with commas',
        sink: sink,
      );

      final output = sink.toString().trim();
      check(output).equals(
        '::error file=lib/src/foo.dart,line=10,title=Error%3A Title%2C with commas::'
        'Compile error line 1%0ACompile error line 2: with colons',
      );
    });

    test('emitGitHubWarning formats and escapes correctly', () {
      final sink = StringBuffer();
      emitGitHubWarning(
        'Unreleased local sibling\nSecond line',
        file: 'pubspec.yaml',
        title: 'Warning Title',
        sink: sink,
      );

      final output = sink.toString().trim();
      check(output).equals(
        '::warning file=pubspec.yaml,title=Warning Title::'
        'Unreleased local sibling%0ASecond line',
      );
    });
  });
}
