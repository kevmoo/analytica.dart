import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import 'analyzer/path_filter.dart';

export 'package:io/io.dart' show ExitCode;

export 'analyzer/path_filter.dart';

/// Standard CLI argument parsing options and helpers across Analytica tools.
extension AnalyticaArgParserExtensions on ArgParser {
  /// Adds a standard `--sdk-path` option to this parser.
  void addSdkPathOption({
    String help = 'Path to the Dart SDK root (overrides auto-discovery).',
  }) {
    addOption('sdk-path', help: help);
  }

  /// Adds a standard `--format` / `-f` option to this parser.
  void addFormatOption({
    List<String> allowed = const ['markdown', 'json', 'github'],
    String defaultsTo = 'markdown',
    String help = 'Output formatting mode.',
  }) {
    addOption(
      'format',
      abbr: 'f',
      help: help,
      allowed: allowed,
      defaultsTo: defaultsTo,
    );
  }

  /// Adds a standard `--help` / `-h` flag to this parser.
  void addHelpFlag({String help = 'Print usage information.'}) {
    addFlag('help', abbr: 'h', negatable: false, help: help);
  }

  /// Adds a standard `--version` flag to this parser.
  void addVersionFlag({String help = 'Print version information.'}) {
    addFlag('version', negatable: false, help: help);
  }

  /// Adds standardized `--exclude` and `--[no-]ignore-generated` options to
  /// this parser.
  void addPathFilterOptions() {
    addMultiOption(
      'exclude',
      help:
          'Glob patterns of files/directories to exclude (repeatable or '
          'comma-separated).',
      valueHelp: 'glob',
      // Split in parsePathFilter instead: a brace group such as
      // `**/*.{g,freezed}.dart` contains commas that must survive.
      splitCommas: false,
    );
    addFlag(
      'ignore-generated',
      defaultsTo: true,
      help:
          'Exclude generated files (*.g.dart, *.freezed.dart, *.mocks.dart, '
          'etc.).',
    );
  }
}

/// Splits a comma-separated list of glob patterns, ignoring commas inside a
/// brace group or a character class.
///
/// `**/*.{g,freezed}.dart,lib/**` yields `['**/*.{g,freezed}.dart', 'lib/**']`
/// rather than tearing the brace group apart on its inner comma, and
/// `**/*_[0,1].dart` is likewise left whole.
List<String> splitGlobPatterns(String value) {
  final parts = <String>[];
  final buffer = StringBuffer();
  var depth = 0;
  for (final rune in value.runes) {
    final char = String.fromCharCode(rune);
    if (char == '{' || char == '[') {
      depth++;
    } else if (char == '}' || char == ']') {
      if (depth > 0) depth--;
    } else if (char == ',' && depth == 0) {
      parts.add(buffer.toString());
      buffer.clear();
      continue;
    }
    buffer.write(char);
  }
  parts.add(buffer.toString());
  return parts;
}

/// Parses a [PathFilter] from the standard `--exclude` and `--ignore-generated`
/// options in [results].
PathFilter parsePathFilter(
  ArgResults results, {
  Iterable<String> defaultExcludes = const [],
}) {
  final rawExcludes = results.options.contains('exclude')
      ? results.multiOption('exclude')
      : const <String>[];
  final userExcludes = rawExcludes
      .expand(splitGlobPatterns)
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty);

  final ignoreGenerated = results.options.contains('ignore-generated')
      ? results.flag('ignore-generated')
      : true;

  return PathFilter(
    excludePatterns: [...defaultExcludes, ...userExcludes],
    ignoreGenerated: ignoreGenerated,
  );
}

/// Parses a 1-based line range of format `<start>-<end>` (e.g. `45-80`).
(int, int) parseLineBounds(String lines) {
  final parts = lines.split('-');
  if (parts.length != 2) {
    throw FormatException(
      'Invalid lines format "$lines". Expected <start>-<end> (e.g. 45-80).',
    );
  }

  final start = int.tryParse(parts[0].trim());
  final end = int.tryParse(parts[1].trim());

  if (start == null || start < 1) {
    throw FormatException('Invalid start line: "${parts[0]}". Must be >= 1.');
  }
  if (end == null || end < start) {
    throw FormatException(
      'Invalid end line: "${parts[1]}". Must be >= start line ($start).',
    );
  }

  return (start, end);
}

/// Parses a non-negative integer or throws a [FormatException].
int parseNonNegativeInt(String val, String name) {
  final parsed = int.tryParse(val);
  if (parsed == null || parsed < 0) {
    throw FormatException(
      'Invalid $name: $val. Must be a non-negative integer.',
    );
  }
  return parsed;
}

/// Resolves a file target and optional line specifier from command arguments.
///
/// Supports `<file.dart>:<start>-<end>` syntax as well as plain file paths.
({String filePath, String? linesString}) resolveTargetFileAndLines(
  String rawTarget, {
  String? explicitLines,
}) {
  var filePath = rawTarget;
  var linesString = explicitLines;

  final match = RegExp(r'^(.*?):(\d+(?:-\d+)?)$').firstMatch(rawTarget);
  if (match != null) {
    if (explicitLines != null) {
      throw const FormatException(
        'Target lines specified both via option and file path.',
      );
    }
    filePath = match.group(1)!;
    linesString = match.group(2)!;
  }

  return (filePath: p.normalize(filePath), linesString: linesString);
}

/// Parses a comma-separated string into a trimmed, non-empty list of items.
///
/// Returns an empty list if [value] is null, empty, or contains only
/// whitespace.
List<String> parseCommaSeparated(String? value) {
  if (value == null || value.trim().isEmpty) return const [];
  return value
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
}
