/// Representation of a parsed marked section in a README.
class MarkedSection {
  final String id;
  final int startIndex;
  final int endIndex;
  final String startMarker;
  final String endMarker;
  final String rawInnerContent;

  const MarkedSection({
    required this.id,
    required this.startIndex,
    required this.endIndex,
    required this.startMarker,
    required this.endMarker,
    required this.rawInnerContent,
  });

  /// Extracts the content inside the code fence, if present.
  String? extractCodeFenceContent() {
    final trimmed = rawInnerContent.trim();
    if (!trimmed.startsWith('```')) return null;

    final firstLineEnd = trimmed.indexOf('\n');
    if (firstLineEnd == -1) return null;

    final lastFence = trimmed.lastIndexOf('```');
    if (lastFence <= firstLineEnd) return null;

    return trimmed.substring(firstLineEnd + 1, lastFence);
  }
}

/// Finds all marked sections in a markdown document.
List<MarkedSection> findMarkedSections(String markdown) {
  final results = <MarkedSection>[];

  // Matches <!-- CLI_README_START [id] --> or <!-- CLI_HELP_START [id] -->
  final startRegex = RegExp(
    r'<!--\s*(?:CLI_README_START|CLI_HELP_START)(?:\s+([a-zA-Z0-9_-]+))?\s*-->',
    caseSensitive: false,
  );

  for (final match in startRegex.allMatches(markdown)) {
    final id = match.group(1) ?? '';
    final startMarker = match.group(0)!;
    final startIndex = match.start;

    // Search for matching end marker after this start marker
    final escapedId = RegExp.escape(id);
    final endPattern = id.isEmpty
        ? r'<!--\s*(?:CLI_README_END|CLI_HELP_END)\s*-->'
        : '<!--\\s*(?:CLI_README_END|CLI_HELP_END)\\s+$escapedId\\s*-->';

    final endRegex = RegExp(endPattern, caseSensitive: false);
    final endMatch = endRegex.firstMatch(markdown.substring(match.end));

    if (endMatch != null) {
      final actualEndStart = match.end + endMatch.start;
      final actualEndIndex = match.end + endMatch.end;
      final endMarker = endMatch.group(0)!;
      final rawInnerContent = markdown.substring(match.end, actualEndStart);

      results.add(
        MarkedSection(
          id: id,
          startIndex: startIndex,
          endIndex: actualEndIndex,
          startMarker: startMarker,
          endMarker: endMarker,
          rawInnerContent: rawInnerContent,
        ),
      );
    }
  }

  return results;
}

/// Replaces a marked section in [markdown] with [newInnerContent].
String replaceMarkedSection({
  required String markdown,
  required MarkedSection section,
  required String newInnerContent,
}) {
  final buffer = StringBuffer();
  buffer.write(markdown.substring(0, section.startIndex));
  buffer.writeln(section.startMarker);
  buffer.writeln(newInnerContent.trim());
  buffer.write(section.endMarker);
  buffer.write(markdown.substring(section.endIndex));
  return buffer.toString();
}

/// Replaces a marked section by [id] in [markdown] dynamically.
String replaceMarkedSectionById({
  required String markdown,
  required String id,
  required String newInnerContent,
}) {
  final sections = findMarkedSections(markdown);
  final match = sections.where((s) => s.id == id).firstOrNull;
  if (match == null) return markdown;
  return replaceMarkedSection(
    markdown: markdown,
    section: match,
    newInnerContent: newInnerContent,
  );
}
