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

  static String _normalizePattern(String raw) {
    var pat = raw.trim().replaceAll(r'\', '/');
    if (pat.startsWith('./')) {
      pat = pat.substring(2);
    }
    if (pat.startsWith('/')) {
      pat = pat.substring(1);
    }
    // If the pattern contains no slash, treat it as matching anywhere.
    if (!pat.contains('/') && !pat.startsWith('**')) {
      return '**/$pat';
    }
    return pat;
  }

  /// Returns `true` if [relativePath] matches any active exclusion pattern or
  /// contains a standard ignored directory segment.
  bool isExcluded(String relativePath) {
    final normalized = p.posix.normalize(relativePath).replaceAll(r'\', '/');
    var clean = normalized;
    if (clean.startsWith('./')) {
      clean = clean.substring(2);
    } else if (clean.startsWith('/')) {
      clean = clean.substring(1);
    }

    final segments = clean.split('/');
    if (segments.contains('.dart_tool') ||
        segments.contains('.git') ||
        segments.contains('.idea') ||
        segments.contains('.vscode') ||
        (segments.isNotEmpty && segments.first == 'build')) {
      return true;
    }

    return WildcardPattern.anyMatch(_wildcards, clean);
  }
}
