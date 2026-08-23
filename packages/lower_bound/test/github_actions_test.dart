import 'package:checks/checks.dart';
import 'package:lower_bound/lower_bound.dart';
import 'package:test/test.dart';

void main() {
  group('GitHub Actions Helpers', () {
    test('emitGitHubError formats correctly', () {
      final sink = StringBuffer();
      emitGitHubError(
        'Compile error at floor',
        file: 'lib/src/foo.dart',
        line: 10,
        title: 'Error Title',
        sink: sink,
      );

      final output = sink.toString().trim();
      check(output).equals(
        '::error file=lib/src/foo.dart,line=10,title=Error Title::Compile error at floor',
      );
    });

    test('emitGitHubWarning formats correctly', () {
      final sink = StringBuffer();
      emitGitHubWarning(
        'Unreleased local sibling',
        file: 'pubspec.yaml',
        title: 'Warning Title',
        sink: sink,
      );

      final output = sink.toString().trim();
      check(output).equals(
        '::warning file=pubspec.yaml,title=Warning Title::'
        'Unreleased local sibling',
      );
    });

    test('emitGitHubNotice formats correctly', () {
      final sink = StringBuffer();
      emitGitHubNotice('Notice message', sink: sink);

      final output = sink.toString().trim();
      check(output).equals('::notice::Notice message');
    });
  });
}
