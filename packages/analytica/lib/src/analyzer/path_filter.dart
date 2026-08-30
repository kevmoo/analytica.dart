import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

/// Configurable path filter evaluating whether file paths should be excluded
/// from analysis.
///
/// Patterns are matched with `package:glob`, so the full glob syntax is
/// available: `*` and `?` within a segment, `**` across segments, brace
/// expansion (`**/*.{g,freezed}.dart`), and character classes
/// (`**/*_[0-9].dart`). Matching is always case-sensitive and always uses
/// `/` as the separator, on every platform. A literal `[`, `]`, `{` or `}`
/// in a pattern must be escaped with [Glob.quote].
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

  /// Prefix applied to every compiled pattern and every candidate path.
  ///
  /// `package:glob` cannot otherwise express "zero or more leading
  /// directories". The natural spelling, `{**/,}`, parses correctly but throws
  /// `StateError` when matched, because `SequenceNode.canMatchAbsolute` reads
  /// `nodes.first` of the empty alternative. That read only happens when the
  /// options group is the first node of the pattern, so a constant leading
  /// segment keeps the relaxation legal wherever it appears.
  static const _anchor = '<root>/';

  /// The custom exclusion glob patterns configured on this filter.
  final List<String> excludePatterns;

  /// Whether generated Dart files matching [defaultGeneratedPatterns] are
  /// excluded.
  final bool ignoreGenerated;

  final List<Glob> _globs;

  /// Creates a [PathFilter] with optional custom [excludePatterns] and
  /// [ignoreGenerated] toggle (defaults to `true`).
  ///
  /// Throws a [FormatException] naming the offending pattern if any of
  /// [excludePatterns] is not valid glob syntax.
  PathFilter({
    Iterable<String> excludePatterns = const [],
    this.ignoreGenerated = true,
  }) : excludePatterns = List.unmodifiable(excludePatterns),
       _globs = _compileAll([
         ...defaultIgnoredDirectories,
         if (ignoreGenerated) ...defaultGeneratedPatterns,
         ...excludePatterns,
       ]);

  /// Default constant filter instance with standard ignored directories and
  /// generated file exclusion enabled.
  static final PathFilter defaults = PathFilter();

  static List<Glob> _compileAll(Iterable<String> patterns) {
    final globs = <Glob>[];
    for (final raw in patterns) {
      // A trailing comma or an unset CI variable yields a blank entry, which
      // `Glob` rejects. Dropping it keeps such input inert, as it was before.
      if (raw.trim().isEmpty) continue;
      globs.add(_compile(raw));
    }
    return List.unmodifiable(globs);
  }

  static Glob _compile(String raw) {
    // Relax `**` at a path boundary to span zero or more directories, so
    // `**/*.g.dart` also matches a root-level `model.g.dart`. Scoped to
    // boundaries so a caller's own brace group is left intact.
    final anchored = '$_anchor${_normalizePattern(raw)}'.replaceAll(
      '/**/',
      '/{**/,}',
    );
    try {
      // p.posix pins the separator and case sensitivity. Glob's default
      // context is case-insensitive on Windows, which the Linux-only CI
      // would never surface.
      return Glob(anchored, context: p.posix);
    } on FormatException catch (e) {
      throw FormatException('Invalid exclude pattern "$raw": ${e.message}');
    }
  }

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

    // Patterns describe the scanned tree, so a path that escapes it — as
    // `undead --extra-roots` and multi-target runs produce via `p.relative` —
    // is matched on its in-tree remainder. `**` will not match a leading
    // `../` on its own.
    while (clean.startsWith('../')) {
      clean = clean.substring(3);
    }

    final candidate = '$_anchor$clean';
    for (final glob in _globs) {
      if (glob.matches(candidate)) return true;
    }
    return false;
  }
}
