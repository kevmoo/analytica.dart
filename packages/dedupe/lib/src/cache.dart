import 'dart:convert';
import 'dart:io';

import 'package:analyzer/source/line_info.dart';
import 'package:path/path.dart' as p;

import 'ast_extractor.dart';
import 'models.dart';
import 'tokenizer.dart';
import 'version.dart';

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
  static const _cacheFormatVersion = '1';

  final String cacheDirPath;
  final bool enabled;
  final DedupeOptions options;
  final String sdkVersion;
  final String packageVersion;

  late final String _optionsHash = _computeOptionsHash();

  DedupeCacheManager({
    required this.cacheDirPath,
    required this.enabled,
    required this.options,
    String? sdkVersion,
    String? packageVersion,
  }) : sdkVersion = sdkVersion ?? Platform.version,
       packageVersion = packageVersion ?? dedupeVersion;

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
      final data = jsonDecode(jsonStr);
      if (data is! Map<String, dynamic>) return null;
      if (data['version'] != _cacheFormatVersion) return null;
      if (data['relPath'] != relPath) return null;
      if (data['contentHash'] != contentHash) return null;
      if (data['optionsHash'] != _optionsHash) return null;

      final entryData = data['entry'];
      if (entryData is! Map<String, dynamic>) return null;

      return CachedFileEntry.fromJson(entryData, fileIndex: fileIndex);
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
        'version': _cacheFormatVersion,
        'relPath': relPath,
        'contentHash': contentHash,
        'optionsHash': _optionsHash,
        'entry': entry.toJson(),
      };

      final tempFile = File('${cacheFile.path}.$pid.tmp');
      tempFile.writeAsStringSync(jsonEncode(payload), flush: true);
      try {
        tempFile.renameSync(cacheFile.path);
      } on FileSystemException {
        if (cacheFile.existsSync()) {
          try {
            cacheFile.deleteSync();
          } catch (_) {}
        }
        tempFile.renameSync(cacheFile.path);
      }
    } catch (_) {
      // Graceful error handling
    }
  }

  static final _cacheEntryFileNamePattern = RegExp(r'^[0-9a-fA-F]{16}\.json$');
  static final _cacheEntryDirPattern = RegExp(r'^[0-9a-fA-F]{2}$');

  bool _isCacheEntryFile(String filePath) {
    final fileName = p.basename(filePath);
    if (!_cacheEntryFileNamePattern.hasMatch(fileName)) return false;
    final parentDir = p.basename(p.dirname(filePath));
    return _cacheEntryDirPattern.hasMatch(parentDir);
  }

  /// Returns the `relPath` of a dedupe cache entry file, or `null` if [file]
  /// is not one: unreadable, not JSON, or missing any schema field.
  String? _cacheEntryRelPath(File file) {
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map<String, dynamic>) return null;
      if (decoded['version'] != _cacheFormatVersion) return null;
      for (final key in const ['optionsHash', 'contentHash', 'entry']) {
        if (decoded[key] == null) return null;
      }
      return decoded['relPath'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// Prunes stale cache entries that no longer correspond to [activeRelPaths].
  void pruneStale(Set<String> activeRelPaths) {
    if (!enabled) return;

    final cacheDir = Directory(cacheDirPath);
    if (!cacheDir.existsSync()) return;

    try {
      final files = cacheDir.listSync(recursive: true).whereType<File>();
      for (final file in files) {
        if (!_isCacheEntryFile(file.path)) continue;
        final relPath = _cacheEntryRelPath(file);
        if (relPath == null || activeRelPaths.contains(relPath)) continue;
        try {
          file.deleteSync();
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Clears dedupe cache entries from the cache directory without removing
  /// unrelated user files.
  void clear() {
    final cacheDir = Directory(cacheDirPath);
    if (!cacheDir.existsSync()) return;

    try {
      final files = cacheDir.listSync(recursive: true).whereType<File>();
      for (final file in files) {
        _deleteCacheEntryFile(file);
      }
      _deleteEmptyShardDirs(cacheDir);
    } catch (_) {}
  }

  void _deleteCacheEntryFile(File file) {
    if (!_isCacheEntryFile(file.path)) return;
    if (_cacheEntryRelPath(file) == null) return;
    try {
      file.deleteSync();
    } catch (_) {}
  }

  void _deleteEmptyShardDirs(Directory cacheDir) {
    for (final entity in cacheDir.listSync()) {
      if (entity is! Directory) continue;
      if (!_cacheEntryDirPattern.hasMatch(p.basename(entity.path))) continue;
      try {
        if (entity.listSync().isEmpty) {
          entity.deleteSync();
        }
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
        '$packageVersion|$sdkVersion|'
        '${options.minTokens}|${options.minLines}|'
        '${options.ignoreComments}|${options.ignoreLiterals}|'
        '${options.ignoreIdentifiers}';
    return computeContentHash(raw);
  }
}
