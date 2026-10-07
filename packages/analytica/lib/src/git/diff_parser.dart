import 'dart:math' as math;

import 'models.dart';

/// Parser for unified diff strings produced by `git diff` or `diff -u`.
class GitDiffParser {
  static final RegExp _hunkHeaderPattern = RegExp(
    r'^@@\s+-(\d+)(?:,(\d+))?\s+\+(\d+)(?:,(\d+))?\s+@@(?:[ \t]+(.*))?$',
  );

  static final RegExp _diffGitQuotedPattern = RegExp(
    r'^diff --git\s+"a/(.+?)"\s+"b/(.+?)"$',
  );
  static final RegExp _diffGitUnquotedPattern = RegExp(
    r'^diff --git\s+a/(.+?)\s+b/(.+?)$',
  );

  static final RegExp _minusFilePattern = RegExp(r'^---\s+(.+)$');
  static final RegExp _plusFilePattern = RegExp(r'^\+\+\+\s+(.+)$');

  static const int _maxLineNumber = 0x3fffffffffffffff;

  static String _cleanPath(String raw) {
    var cleaned = raw.trim();
    if (cleaned.length >= 2 &&
        cleaned.startsWith('"') &&
        cleaned.endsWith('"')) {
      cleaned = cleaned.substring(1, cleaned.length - 1);
    }
    final tabIdx = cleaned.indexOf('\t');
    if (tabIdx != -1) {
      cleaned = cleaned.substring(0, tabIdx).trim();
    }
    if (cleaned.startsWith('a/') || cleaned.startsWith('b/')) {
      cleaned = cleaned.substring(2);
    }
    return cleaned;
  }

  /// Parses a unified diff string into a list of [GitFileDiff] objects.
  static List<GitFileDiff> parse(String unifiedDiff) {
    if (unifiedDiff.trim().isEmpty) return const [];

    final rawLines = unifiedDiff.split('\n');
    final fileDiffs = <GitFileDiff>[];

    var sectionStart = 0;
    ({String oldPath, String newPath})? currentHeader;

    for (var i = 0; i < rawLines.length; i++) {
      final line = rawLines[i];
      final diffMatch =
          _diffGitQuotedPattern.firstMatch(line) ??
          _diffGitUnquotedPattern.firstMatch(line);
      if (diffMatch == null) continue;

      final prevDiff = _parseFileSection(
        rawLines,
        sectionStart,
        i,
        currentHeader,
      );
      if (prevDiff != null) fileDiffs.add(prevDiff);

      currentHeader = (
        oldPath: _cleanPath(diffMatch.group(1)!),
        newPath: _cleanPath(diffMatch.group(2)!),
      );
      sectionStart = i + 1;
    }

    final lastDiff = _parseFileSection(
      rawLines,
      sectionStart,
      rawLines.length,
      currentHeader,
    );
    if (lastDiff != null) fileDiffs.add(lastDiff);

    return List.unmodifiable(fileDiffs);
  }

  static GitFileDiff? _parseFileSection(
    List<String> rawLines,
    int start,
    int end,
    ({String oldPath, String newPath})? headerPaths,
  ) {
    var currentOldPath = headerPaths?.oldPath;
    var currentNewPath = headerPaths?.newPath;
    var isNew = false;
    var isDeleted = false;
    var isRenamed = false;
    final currentHunks = <DiffHunk>[];

    for (var i = start; i < end; i++) {
      final line = rawLines[i];
      if (line.startsWith('new file mode')) {
        isNew = true;
      } else if (line.startsWith('deleted file mode')) {
        isDeleted = true;
      } else if (line.startsWith('rename from ') ||
          line.startsWith('rename to ')) {
        isRenamed = true;
      } else if (i + 1 < end &&
          line.startsWith('---') &&
          rawLines[i + 1].startsWith('+++')) {
        final paths = _parseFileHeaderPair(
          line,
          rawLines[i + 1],
          currentOldPath,
          currentNewPath,
        );
        currentOldPath = paths.oldPath;
        currentNewPath = paths.newPath;
        i++;
      } else if (_tryParseHunk(rawLines, i, end) case final parsedHunk?) {
        currentHunks.add(parsedHunk.hunk);
        i = parsedHunk.nextIndex - 1;
      }
    }

    if ((currentOldPath ?? currentNewPath) == null && currentHunks.isEmpty) {
      return null;
    }

    return GitFileDiff(
      oldPath: currentOldPath == '/dev/null' ? null : currentOldPath,
      newPath: currentNewPath == '/dev/null' ? null : currentNewPath,
      hunks: List.unmodifiable(currentHunks),
      isNew: isNew,
      isDeleted: isDeleted,
      isRenamed: isRenamed,
    );
  }

  static ({String? oldPath, String? newPath}) _parseFileHeaderPair(
    String minusLine,
    String plusLine,
    String? currentOldPath,
    String? currentNewPath,
  ) {
    var oldPath = currentOldPath;
    var newPath = currentNewPath;
    final minusMatch = _minusFilePattern.firstMatch(minusLine);
    if (minusMatch != null) {
      final rawOld = _cleanPath(minusMatch.group(1)!);
      if (oldPath == null || rawOld == '/dev/null') {
        oldPath = rawOld;
      }
      final plusMatch = _plusFilePattern.firstMatch(plusLine);
      if (plusMatch != null) {
        final rawNew = _cleanPath(plusMatch.group(1)!);
        if (newPath == null || rawNew == '/dev/null') {
          newPath = rawNew;
        }
      }
    }
    return (oldPath: oldPath, newPath: newPath);
  }

  static ({DiffHunk hunk, int nextIndex})? _tryParseHunk(
    List<String> rawLines,
    int headerIndex,
    int endIndex,
  ) {
    final hunkMatch = _hunkHeaderPattern.firstMatch(rawLines[headerIndex]);
    if (hunkMatch == null) return null;

    final oldStart = int.tryParse(hunkMatch.group(1)!);
    final oldCount = hunkMatch.group(2) != null
        ? int.tryParse(hunkMatch.group(2)!)
        : 1;
    final newStart = int.tryParse(hunkMatch.group(3)!);
    final newCount = hunkMatch.group(4) != null
        ? int.tryParse(hunkMatch.group(4)!)
        : 1;
    if (oldStart == null ||
        oldCount == null ||
        newStart == null ||
        newCount == null) {
      return null;
    }

    final sectionHeading = hunkMatch.group(5)?.trim();
    final body = _parseHunkBody(rawLines, headerIndex + 1, endIndex, newStart);

    return (
      hunk: DiffHunk(
        oldStart: oldStart,
        oldCount: oldCount,
        newStart: newStart,
        newCount: newCount,
        sectionHeading: sectionHeading != null && sectionHeading.isNotEmpty
            ? sectionHeading
            : null,
        lines: List.unmodifiable(body.lines),
        addedOrModifiedRanges: List.unmodifiable(body.addedRanges),
      ),
      nextIndex: body.nextIndex,
    );
  }

  static ({List<String> lines, List<LineRange> addedRanges, int nextIndex})
  _parseHunkBody(
    List<String> rawLines,
    int startIndex,
    int endIndex,
    int newStart,
  ) {
    final hunkLines = <String>[];
    final addedRanges = <LineRange>[];
    var currentNew = math.min(_maxLineNumber, math.max(1, newStart));
    int? rangeStart;
    var rangeEnd = 1;

    var i = startIndex;
    while (i < endIndex) {
      final hunkLine = rawLines[i];
      if (_hunkHeaderPattern.hasMatch(hunkLine)) break;

      if (hunkLine.startsWith('+')) {
        rangeStart ??= currentNew;
        rangeEnd = currentNew;
        currentNew = math.min(_maxLineNumber, currentNew + 1);
      } else if (hunkLine.startsWith(' ') || hunkLine.isEmpty) {
        if (rangeStart != null) {
          addedRanges.add(LineRange(rangeStart, rangeEnd));
          rangeStart = null;
        }
        currentNew = math.min(_maxLineNumber, currentNew + 1);
      } else if (!hunkLine.startsWith('-') && !hunkLine.startsWith(r'\')) {
        break;
      }

      hunkLines.add(hunkLine);
      i++;
    }

    if (rangeStart != null) {
      addedRanges.add(LineRange(rangeStart, rangeEnd));
    }

    return (lines: hunkLines, addedRanges: addedRanges, nextIndex: i);
  }
}
