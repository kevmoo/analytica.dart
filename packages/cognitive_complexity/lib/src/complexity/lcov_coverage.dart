import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'complexity_analyzer.dart';

/// Line-coverage metrics for a single Dart declaration span.
final class DeclarationCoverage {
  /// Whether the declaration's source file appeared in the LCOV report.
  ///
  /// Both `dart test --coverage-path` and `flutter test --coverage` omit files
  /// never imported by any test, so `loaded == false` means 0% executed
  /// coverage rather than missing data.
  final bool loaded;

  /// Number of executable lines in the declaration with hit count `> 0`.
  final int coveredLines;

  /// Total executable lines in the declaration recorded in the LCOV report.
  final int executableLines;

  /// Sorted 1-based executable line numbers in the declaration with 0 hits.
  final List<int> uncoveredLines;

  const DeclarationCoverage({
    required this.loaded,
    required this.coveredLines,
    required this.executableLines,
    required this.uncoveredLines,
  });

  /// Line coverage percentage (`0.0`–`100.0`, rounded to 1 decimal place).
  ///
  /// Returns `0.0` when [loaded] is `false`, and `null` when the file was
  /// loaded but the declaration has no executable lines in the LCOV report.
  double? get percent {
    if (!loaded) return 0.0;
    if (executableLines == 0) return null;
    return (coveredLines * 1000 / executableLines).round() / 10;
  }

  /// Formats a compact coverage label such as `75% (9/12)`, `0% (unloaded)`,
  /// or `n/a`.
  String formatShort() {
    if (!loaded) return '0% (unloaded)';
    if (executableLines == 0) return 'n/a';
    final rounded = (coveredLines * 100 / executableLines).round();
    return '$rounded% ($coveredLines/$executableLines)';
  }

  /// Compacts [uncoveredLines] into line ranges such as `L48-50, L52, L61-62`.
  ///
  /// When more than [maxRanges] disjoint ranges exist, emits the first
  /// [maxRanges] ranges followed by `, +N more`. Returns an empty string when
  /// [uncoveredLines] is empty.
  String formatUncoveredRanges({int maxRanges = 5}) {
    if (uncoveredLines.isEmpty) return '';
    final ranges = <String>[];
    var start = uncoveredLines.first;
    var prev = start;
    for (var i = 1; i < uncoveredLines.length; i++) {
      final line = uncoveredLines[i];
      if (line == prev + 1) {
        prev = line;
      } else {
        ranges.add(start == prev ? 'L$start' : 'L$start-$prev');
        start = prev = line;
      }
    }
    ranges.add(start == prev ? 'L$start' : 'L$start-$prev');

    if (maxRanges > 0 && ranges.length > maxRanges) {
      final shown = ranges.take(maxRanges).join(', ');
      final extra = ranges.length - maxRanges;
      return '$shown, +$extra more';
    }
    return ranges.join(', ');
  }

  Map<String, dynamic> toJson() => {
    'loaded': loaded,
    'covered_lines': coveredLines,
    'executable_lines': executableLines,
    'percent': percent,
    'uncovered_lines': uncoveredLines,
  };
}

/// Parsed LCOV line-coverage hitmap indexed by canonicalized file path.
final class LcovCoverage {
  static final _daPattern = RegExp(r'^DA:(\d+),(\d+)(?:,.*)?$');

  final Map<String, Map<int, int>> _fileHits;
  final String _baseDirectory;

  LcovCoverage._(this._fileHits, this._baseDirectory);

  /// Parses an LCOV report from [content].
  ///
  /// Relative `SF:` paths are resolved against [baseDirectory] (defaulting to
  /// [Directory.current]) and, if not found there on disk, against
  /// [fallbackDirectory] when provided. Duplicate `SF:` records for the same
  /// file are merged by summing line hit counts.
  factory LcovCoverage.parse(
    String content, {
    String? baseDirectory,
    String? fallbackDirectory,
  }) {
    final baseDir = p.normalize(
      p.absolute(baseDirectory ?? Directory.current.path),
    );
    final fallbackDir = fallbackDirectory == null
        ? null
        : p.normalize(p.absolute(fallbackDirectory));
    final fileHits = <String, Map<int, int>>{};
    Map<int, int>? currentFile;

    for (final rawLine in const LineSplitter().convert(content)) {
      final line = rawLine.trim();
      if (line == 'end_of_record') {
        currentFile = null;
        continue;
      }
      if (line.startsWith('SF:')) {
        final sourcePath = line.substring(3).trim();
        currentFile = sourcePath.isEmpty
            ? null
            : fileHits.putIfAbsent(
                _resolveSourcePath(
                  sourcePath,
                  baseDir: baseDir,
                  fallbackDir: fallbackDir,
                ),
                () => <int, int>{},
              );
        continue;
      }
      if (currentFile == null) continue;
      final match = _daPattern.firstMatch(line);
      if (match == null) continue;
      final lineNum = int.parse(match[1]!);
      if (lineNum == 0) continue;
      final hits = int.parse(match[2]!);
      currentFile[lineNum] = (currentFile[lineNum] ?? 0) + hits;
    }

    return LcovCoverage._(fileHits, baseDir);
  }

  /// Loads and parses an LCOV file at [filePath].
  ///
  /// Throws [FormatException] if [filePath] is empty or is a directory, and
  /// [FileSystemException] if the file does not exist.
  factory LcovCoverage.fromFile(String filePath, {String? baseDirectory}) {
    if (filePath.trim().isEmpty) {
      throw const FormatException('Coverage file path cannot be empty.');
    }
    final type = FileSystemEntity.typeSync(filePath);
    if (type == FileSystemEntityType.directory) {
      throw FormatException(
        'Expected an LCOV file path for --coverage, got directory '
        '"$filePath". Generate LCOV with '
        '"dart test --coverage-path=coverage/lcov.info" or '
        '"flutter test --coverage".',
      );
    }
    if (type == FileSystemEntityType.notFound) {
      throw FileSystemException('Coverage file does not exist', filePath);
    }

    final absPath = p.normalize(p.absolute(filePath));
    final lcovDir = p.dirname(absPath);
    final fallbackDir = p.basename(lcovDir) == 'coverage'
        ? p.dirname(lcovDir)
        : lcovDir;
    return LcovCoverage.parse(
      File(absPath).readAsStringSync(),
      baseDirectory: baseDirectory,
      fallbackDirectory: fallbackDir,
    );
  }

  /// Number of distinct source files present in this LCOV report.
  int get fileCount => _fileHits.length;

  /// Returns a list of [declarations] annotated with line coverage from this
  /// report, leaving `<stdin>` declarations unannotated.
  List<FunctionComplexity> annotateDeclarations(
    List<FunctionComplexity> declarations,
  ) => [
    for (final decl in declarations)
      decl.filePath == '<stdin>'
          ? decl
          : decl.withCoverage(
              coverageFor(
                filePath: decl.filePath,
                startLine: decl.startLine,
                endLine: decl.endLine,
              ),
            ),
  ];

  /// Computes [DeclarationCoverage] for the 1-based inclusive line span
  /// `[startLine, endLine]` in [filePath].
  ///
  /// Returns a [DeclarationCoverage] with `loaded: false` (`percent == 0.0`)
  /// when [filePath] is absent from the LCOV report.
  DeclarationCoverage coverageFor({
    required String filePath,
    required int startLine,
    required int endLine,
  }) {
    final canonical = _canonicalizePath(
      p.isAbsolute(filePath) ? filePath : p.join(_baseDirectory, filePath),
    );
    final hits = _fileHits[canonical];
    if (hits == null) {
      return const DeclarationCoverage(
        loaded: false,
        coveredLines: 0,
        executableLines: 0,
        uncoveredLines: [],
      );
    }

    var covered = 0;
    var executable = 0;
    final uncovered = <int>[];
    for (final entry in hits.entries) {
      if (entry.key < startLine || entry.key > endLine) continue;
      executable++;
      if (entry.value > 0) {
        covered++;
      } else {
        uncovered.add(entry.key);
      }
    }
    uncovered.sort();
    return DeclarationCoverage(
      loaded: true,
      coveredLines: covered,
      executableLines: executable,
      uncoveredLines: List.unmodifiable(uncovered),
    );
  }

  static String _resolveSourcePath(
    String rawPath, {
    required String baseDir,
    required String? fallbackDir,
  }) {
    final normalized = Platform.isWindows
        ? rawPath
        : rawPath.replaceAll(r'\', '/');
    if (p.isAbsolute(normalized)) {
      return _canonicalizePath(normalized);
    }
    final primary = p.normalize(p.join(baseDir, normalized));
    if (File(primary).existsSync()) {
      return _canonicalizePath(primary);
    }
    if (fallbackDir != null) {
      final fallback = p.normalize(p.join(fallbackDir, normalized));
      if (File(fallback).existsSync()) {
        return _canonicalizePath(fallback);
      }
    }
    return _canonicalizePath(primary);
  }

  static String _canonicalizePath(String path) {
    final normalized = p.normalize(p.absolute(path));
    final file = File(normalized);
    if (file.existsSync()) {
      return p.normalize(file.resolveSymbolicLinksSync());
    }
    return normalized;
  }
}
