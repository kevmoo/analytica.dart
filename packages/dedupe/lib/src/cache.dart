import 'dart:convert';
import 'dart:io';

import 'package:analyzer/source/line_info.dart';
import 'package:path/path.dart' as p;

import 'ast_extractor.dart';
import 'models.dart';
import 'tokenizer.dart';

/// Represents a cached file extraction entry storing token sequence metadata
/// and parsed AST candidate units.
class CachedFileEntry {
  final String filePath;
  final String contentHash;
  final int totalLines;
  final List<NormalizedToken> tokens;
  final List<AstCandidateUnit> candidates;

  const CachedFileEntry({
    required this.filePath,
    required this.contentHash,
    required this.totalLines,
    required this.tokens,
    required this.candidates,
  });

  Map<String, dynamic> toJson() => {
    'filePath': filePath,
    'contentHash': contentHash,
    'totalLines': totalLines,
    'tokens': tokens.map((t) => t.toJson()).toList(),
    'candidates': candidates.map((c) => c.toJson()).toList(),
  };

  static CachedFileEntry fromJson(
    Map<String, dynamic> json, {
    int? fileIndex,
  }) => CachedFileEntry(
    filePath: json['filePath'] as String,
    contentHash: json['contentHash'] as String,
    totalLines: json['totalLines'] as int,
    tokens:
        (json['tokens'] as List<dynamic>?)
            ?.map((t) => NormalizedToken.fromJson(t as Map<String, dynamic>))
            .toList() ??
        const [],
    candidates:
        (json['candidates'] as List<dynamic>?)
            ?.map(
              (c) => AstCandidateUnit.fromJson(
                c as Map<String, dynamic>,
                fileIndex: fileIndex,
              ),
            )
            .toList() ??
        const [],
  );

  TokenSequence toTokenSequence(String sourceContent) {
    return TokenSequence(
      filePath: filePath,
      sourceContent: sourceContent,
      lineInfo: LineInfo.fromContent(sourceContent),
      tokens: tokens,
      totalLines: totalLines,
    );
  }
}

/// Manages content-hashed disk caching for token sequences and AST candidates.
class DedupeCacheManager {
  final String cacheDirPath;
  final bool enabled;
  final DedupeOptions options;

  late final String _optionsHash = _computeOptionsHash();

  DedupeCacheManager({
    required this.cacheDirPath,
    required this.enabled,
    required this.options,
  });

  /// Computes a deterministic 64-bit FNV-1a content hash for source [content].
  static String computeContentHash(String content) {
    const fnvPrime = 0x100000001B3;
    var hash = 0xCBF29CE484222325;
    for (var i = 0; i < content.length; i++) {
      hash ^= content.codeUnitAt(i);
      hash = (hash * fnvPrime) & 0x7FFFFFFFFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  /// Retrieves a cached entry for [relPath] if [contentHash] matches and cache
  /// is enabled.
  CachedFileEntry? getEntry({
    required String relPath,
    required String contentHash,
    int? fileIndex,
  }) {
    if (!enabled) return null;

    final cacheFile = File(_getCacheFilePath(relPath));
    if (!cacheFile.existsSync()) return null;

    try {
      final jsonStr = cacheFile.readAsStringSync();
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;
      if (data['contentHash'] != contentHash) return null;
      if (data['optionsHash'] != _optionsHash) return null;

      return CachedFileEntry.fromJson(
        data['entry'] as Map<String, dynamic>,
        fileIndex: fileIndex,
      );
    } catch (_) {
      return null;
    }
  }

  /// Stores a [sequence] and [candidates] for [relPath] and [contentHash] into
  /// the disk cache.
  void putEntry({
    required String relPath,
    required String contentHash,
    required TokenSequence sequence,
    required List<AstCandidateUnit> candidates,
  }) {
    if (!enabled) return;

    final cacheFile = File(_getCacheFilePath(relPath));
    try {
      cacheFile.parent.createSync(recursive: true);
      final entry = CachedFileEntry(
        filePath: relPath,
        contentHash: contentHash,
        totalLines: sequence.totalLines,
        tokens: sequence.tokens,
        candidates: candidates,
      );

      final payload = {
        'version': '1',
        'relPath': relPath,
        'contentHash': contentHash,
        'optionsHash': _optionsHash,
        'entry': entry.toJson(),
      };

      cacheFile.writeAsStringSync(jsonEncode(payload));
    } catch (_) {}
  }

  /// Prunes stale cache entries that no longer correspond to [activeRelPaths].
  void pruneStale(Set<String> activeRelPaths) {
    if (!enabled) return;

    final cacheDir = Directory(cacheDirPath);
    if (!cacheDir.existsSync()) return;

    try {
      final files = cacheDir.listSync(recursive: true).whereType<File>();
      for (final file in files) {
        if (!file.path.endsWith('.json')) continue;
        try {
          final data =
              jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
          final relPath = data['relPath'] as String?;
          if (relPath != null && !activeRelPaths.contains(relPath)) {
            file.deleteSync();
          }
        } catch (_) {
          file.deleteSync();
        }
      }
    } catch (_) {}
  }

  /// Clears the entire cache directory.
  void clear() {
    final cacheDir = Directory(cacheDirPath);
    if (cacheDir.existsSync()) {
      try {
        cacheDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  String _getCacheFilePath(String relPath) {
    final pathHash = computeContentHash(relPath);
    final prefix = pathHash.substring(0, 2);
    return p.join(cacheDirPath, prefix, '$pathHash.json');
  }

  String _computeOptionsHash() {
    final raw =
        '${options.minTokens}|${options.minLines}|'
        '${options.ignoreComments}|${options.ignoreLiterals}|'
        '${options.ignoreIdentifiers}';
    return computeContentHash(raw);
  }
}
