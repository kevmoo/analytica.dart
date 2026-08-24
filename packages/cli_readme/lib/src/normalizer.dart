/// Normalization utilities for command line output and markdown text.
final _ansiEscapeRegex = RegExp(r'\x1B\[[0-9;]*[a-zA-Z]');

/// Normalizes output text for robust comparison.
///
/// 1. Strips ANSI escape sequences (colors, cursor movements).
/// 2. Normalizes Windows CRLF line endings to LF (`\n`).
/// 3. Trims trailing whitespace from every line (resolves `ArgParser.usage`
///    padding).
/// 4. Strips leading and trailing blank lines from the block.
String normalizeText(String input) {
  final noAnsi = input.replaceAll(_ansiEscapeRegex, '');
  final unixLines = noAnsi.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final lines = unixLines.split('\n').map((l) => l.trimRight()).toList();

  // Trim leading empty lines
  while (lines.isNotEmpty && lines.first.trim().isEmpty) {
    lines.removeAt(0);
  }

  // Trim trailing empty lines
  while (lines.isNotEmpty && lines.last.trim().isEmpty) {
    lines.removeLast();
  }

  return lines.join('\n');
}

/// Normalizes a markdown code fence block.
String formatCodeFence({
  required String content,
  String language = 'console',
  String? header,
}) {
  final buffer = StringBuffer();
  buffer.writeln('```$language');
  if (header != null && header.isNotEmpty) {
    buffer.writeln(header.trimRight());
  }
  final normalized = normalizeText(content);
  if (normalized.isNotEmpty) {
    buffer.writeln(normalized);
  }
  buffer.write('```');
  return buffer.toString();
}
