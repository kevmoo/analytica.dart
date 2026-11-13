import 'package:path/path.dart' as p;

import 'glob_matcher.dart';

/// Configurable path filter evaluating whether file paths should be excluded
/// from analysis.
class PathFilter {
  /// Default directory names and glob patterns excluded from scanning.
  static const defaultIgnoredDirectories = <String>[
    '.dart_tool/**',
    '.git/**',
    'build/**',
    '.idea/**',
    '.vscode/**',
  ];

  /// Standard file patterns identifying generated Dart source code.
  static const defaultGeneratedPatterns = <String>[
    '**/*.g.dart',
    '**/*.freezed.dart',
    '**/*.mocks.dart',
    '**/*.config.dart',
    '**/*.reflectable.dart',
    '**/*.gen.dart',
    '**/*.pb.dart',
    '**/*.pbenum.dart',
    '**/*.pbjson.dart',
    '**/*.pbserver.dart',
  ];

  /// The custom exclusion glob patterns configured on this filter.
  final List<String> excludePatterns;

  /// Whether generated Dart files matching [defaultGeneratedPatterns] are
  /// excluded.
  final bool ignoreGenerated;

  final List<WildcardPattern> _wildcards;

  /// Creates a [PathFilter] with optional custom [excludePatterns] and
  /// [ignoreGenerated] toggle (defaults to `true`).
  PathFilter({
    Iterable<String> excludePatterns = const [],
    this.ignoreGenerated = true,
  }) : excludePatterns = List.unmodifiable(excludePatterns),
       _wildcards = [
         ...defaultIgnoredDirectories.map(
           (p) => WildcardPattern(_normalizePattern(p)),
         ),
         if (ignoreGenerated)
           ...defaultGeneratedPatterns.map(
             (p) => WildcardPattern(_normalizePattern(p)),
           ),
         ...excludePatterns.map((p) => WildcardPattern(_normalizePattern(p))),
       ];

  /// Default constant filter instance with standard ignored directories and
  /// generated file exclusion enabled.
  static final PathFilter defaults = PathFilter();

  static const _ignoredSegments = {'.dart_tool', '.git', '.idea', '.vscode'};

  static String _normalizeRelativePath(String rawPath) {
    final rawParts = p.windows.split(rawPath);
    final relativeParts = p.windows.isAbsolute(rawPath)
        ? rawParts.skip(1)
        : rawParts;
    return p.posix.normalize(p.posix.joinAll(relativeParts));
  }

  static String _normalizePattern(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    final pat = _normalizeRelativePath(trimmed);
    // If the pattern contains no directory segment, treat it as matching
    // anywhere.
    if (p.posix.split(pat) case [final single] when !single.startsWith('**')) {
      return p.posix.join('**', single);
    }
    return pat;
  }

  /// Returns `true` if [relativePath] matches any active exclusion pattern or
  /// contains a standard ignored directory segment.
  bool isExcluded(String relativePath) {
    final clean = _normalizeRelativePath(relativePath);
    final segments = p.posix.split(clean);
    if (segments case ['build', ...]) return true;
    if (segments.any(_ignoredSegments.contains)) return true;

    return WildcardPattern.anyMatch(_wildcards, clean);
  }
}
