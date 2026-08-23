/// Generates a simple line-by-line unified diff between expected and actual
/// text.
String generateDiff({
  required String expected,
  required String actual,
  String expectedHeader = 'expected (from CLI)',
  String actualHeader = 'actual (in README.md)',
}) {
  final expLines = expected.split('\n');
  final actLines = actual.split('\n');

  final buffer = StringBuffer();
  buffer.writeln('--- $actualHeader');
  buffer.writeln('+++ $expectedHeader');

  final maxLen = expLines.length > actLines.length
      ? expLines.length
      : actLines.length;

  for (var i = 0; i < maxLen; i++) {
    final expLine = i < expLines.length ? expLines[i] : null;
    final actLine = i < actLines.length ? actLines[i] : null;

    if (expLine == actLine) {
      buffer.writeln('  $actLine');
    } else {
      if (actLine != null) {
        buffer.writeln('- $actLine');
      }
      if (expLine != null) {
        buffer.writeln('+ $expLine');
      }
    }
  }

  return buffer.toString();
}
