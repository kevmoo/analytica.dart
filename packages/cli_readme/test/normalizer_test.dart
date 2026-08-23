import 'package:checks/checks.dart';
import 'package:cli_readme/cli_readme.dart';
import 'package:test/test.dart';

void main() {
  group('normalizeText', () {
    test('strips ANSI color escape sequences', () {
      const colored =
          '\x1B[32mUsage: my_tool\x1B[0m\n\x1B[1m  -h, --help\x1B[0m';
      check(normalizeText(colored)).equals('Usage: my_tool\n  -h, --help');
    });

    test('normalizes CRLF to LF', () {
      const crlf = 'line 1\r\nline 2\r\nline 3';
      check(normalizeText(crlf)).equals('line 1\nline 2\nline 3');
    });

    test('trims trailing whitespace on each line', () {
      const padded = 'line 1   \nline 2 \t\nline 3';
      check(normalizeText(padded)).equals('line 1\nline 2\nline 3');
    });

    test(
      'trims leading and trailing empty lines while preserving indentation',
      () {
        const emptySurrounding = '\n\n  line 1  \n\n';
        check(normalizeText(emptySurrounding)).equals('  line 1');
      },
    );
  });

  group('formatCodeFence', () {
    test('wraps content in language code fence with header', () {
      final fence = formatCodeFence(
        content: 'Usage: tool [options]',
        header: r'$ tool --help',
        language: 'console',
      );

      check(
        fence,
      ).equals('```console\n\$ tool --help\nUsage: tool [options]\n```');
    });
  });
}
