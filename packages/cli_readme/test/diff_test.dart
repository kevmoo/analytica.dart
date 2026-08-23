import 'package:checks/checks.dart';
import 'package:cli_readme/src/diff.dart';
import 'package:test/test.dart';

void main() {
  test('generateDiff produces readable line-by-line diff', () {
    const expected = 'line 1\nline 2 (new)\nline 3';
    const actual = 'line 1\nline 2 (old)\nline 3';

    final diff = generateDiff(expected: expected, actual: actual);
    check(diff).contains('- line 2 (old)');
    check(diff).contains('+ line 2 (new)');
    check(diff).contains('  line 1');
  });
}
