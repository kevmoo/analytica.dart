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

  final buffer = StringBuffer()
    ..writeln('--- $actualHeader')
    ..writeln('+++ $expectedHeader');

  final maxLen = expLines.length > actLines.length
      ? expLines.length
      : actLines.length;

  for (var i = 0; i < maxLen; i++) {
    final exp = i < expLines.length ? expLines[i] : null;
    final act = i < actLines.length ? actLines[i] : null;
    _writeDiffLine(buffer, exp, act);
  }

  return buffer.toString();
}

void _writeDiffLine(StringBuffer buffer, String? exp, String? act) {
  if (exp == act) {
    buffer.writeln('  $act');
    return;
  }
  if (act != null) buffer.writeln('- $act');
  if (exp != null) buffer.writeln('+ $exp');
}
