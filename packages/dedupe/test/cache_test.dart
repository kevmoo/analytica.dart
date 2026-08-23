import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:dedupe/dedupe.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('DedupeCacheManager', () {
    late Directory tempDir;
    late String cacheDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('dedupe_cache_test_');
      cacheDir = p.join(tempDir.path, 'cache');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('putEntry and getEntry store and load valid cache data', () {
      const options = DedupeOptions(targetPath: '.');
      final cache = DedupeCacheManager(
        cacheDirPath: cacheDir,
        enabled: true,
        options: options,
      );

      const code = 'void testMethod() { print(1); }';
      final hash = DedupeCacheManager.computeContentHash(code);

      const extractor = AstExtractor(minTokens: 5, minLines: 1);
      final (seq, candidates) = extractor.extract(
        filePath: 'lib/sample.dart',
        content: code,
        fileIndex: 0,
      );

      cache.putEntry(
        relPath: 'lib/sample.dart',
        contentHash: hash,
        sequence: seq,
        candidates: candidates,
      );

      final cached = cache.getEntry(
        relPath: 'lib/sample.dart',
        contentHash: hash,
        fileIndex: 0,
      );

      check(cached).isNotNull();
      check(cached!.filePath).equals('lib/sample.dart');
      check(cached.contentHash).equals(hash);
      check(cached.tokens.length).equals(seq.tokens.length);
      check(cached.candidates.length).equals(candidates.length);
    });

    test('getEntry returns null on content hash mismatch', () {
      const options = DedupeOptions(targetPath: '.');
      final cache = DedupeCacheManager(
        cacheDirPath: cacheDir,
        enabled: true,
        options: options,
      );

      const code = 'void testMethod() { print(1); }';
      final hash1 = DedupeCacheManager.computeContentHash(code);
      final hash2 = DedupeCacheManager.computeContentHash('void modified() {}');

      const extractor = AstExtractor(minTokens: 5, minLines: 1);
      final (seq, candidates) = extractor.extract(
        filePath: 'lib/sample.dart',
        content: code,
        fileIndex: 0,
      );

      cache.putEntry(
        relPath: 'lib/sample.dart',
        contentHash: hash1,
        sequence: seq,
        candidates: candidates,
      );

      final cached = cache.getEntry(
        relPath: 'lib/sample.dart',
        contentHash: hash2,
        fileIndex: 0,
      );

      check(cached).isNull();
    });

    test('getEntry returns null on options mismatch', () {
      const options1 = DedupeOptions(targetPath: '.', minTokens: 40);
      const options2 = DedupeOptions(targetPath: '.', minTokens: 50);

      final cache1 = DedupeCacheManager(
        cacheDirPath: cacheDir,
        enabled: true,
        options: options1,
      );
      final cache2 = DedupeCacheManager(
        cacheDirPath: cacheDir,
        enabled: true,
        options: options2,
      );

      const code = 'void testMethod() { print(1); }';
      final hash = DedupeCacheManager.computeContentHash(code);

      const extractor = AstExtractor(minTokens: 5, minLines: 1);
      final (seq, candidates) = extractor.extract(
        filePath: 'lib/sample.dart',
        content: code,
        fileIndex: 0,
      );

      cache1.putEntry(
        relPath: 'lib/sample.dart',
        contentHash: hash,
        sequence: seq,
        candidates: candidates,
      );

      final cached = cache2.getEntry(
        relPath: 'lib/sample.dart',
        contentHash: hash,
        fileIndex: 0,
      );

      check(cached).isNull();
    });

    test('pruneStale removes deleted files from cache', () {
      const options = DedupeOptions(targetPath: '.');
      final cache = DedupeCacheManager(
        cacheDirPath: cacheDir,
        enabled: true,
        options: options,
      );

      const code = 'void test() {}';
      final hash = DedupeCacheManager.computeContentHash(code);
      const extractor = AstExtractor(minTokens: 2, minLines: 1);
      final (seq, cands) = extractor.extract(
        filePath: 'lib/old.dart',
        content: code,
        fileIndex: 0,
      );

      cache.putEntry(
        relPath: 'lib/old.dart',
        contentHash: hash,
        sequence: seq,
        candidates: cands,
      );

      check(
        cache.getEntry(relPath: 'lib/old.dart', contentHash: hash),
      ).isNotNull();

      // Prune with active set that does not contain lib/old.dart
      cache.pruneStale({'lib/new.dart'});

      check(
        cache.getEntry(relPath: 'lib/old.dart', contentHash: hash),
      ).isNull();
    });

    test('pruneStale does not delete unrelated or malformed JSON files', () {
      const options = DedupeOptions(targetPath: '.');
      final cache = DedupeCacheManager(
        cacheDirPath: cacheDir,
        enabled: true,
        options: options,
      );

      // Create a mix of unrelated files in cache directory
      final configJson = File(p.join(cacheDir, 'config.json'));
      configJson.parent.createSync(recursive: true);
      configJson.writeAsStringSync(
        '{"settings": true, "relPath": "other.dart"}',
      );

      final malformedJson = File(p.join(cacheDir, 'ab', 'malformed.json'));
      malformedJson.parent.createSync(recursive: true);
      malformedJson.writeAsStringSync('invalid json content {{{');

      final arrayJson = File(p.join(cacheDir, 'cd', '0123456789abcdef.json'));
      arrayJson.parent.createSync(recursive: true);
      arrayJson.writeAsStringSync('[1, 2, 3]');

      final nonCacheJson = File(
        p.join(cacheDir, 'cd', 'fedcba9876543210.json'),
      );
      nonCacheJson.parent.createSync(recursive: true);
      nonCacheJson.writeAsStringSync('{"someKey": "value"}');

      // Run pruneStale with empty active set
      cache.pruneStale(<String>{});

      // All unrelated files must survive
      check(configJson.existsSync()).isTrue();
      check(malformedJson.existsSync()).isTrue();
      check(arrayJson.existsSync()).isTrue();
      check(nonCacheJson.existsSync()).isTrue();
    });

    test(
      'clear removes only valid cache files and empty shard directories',
      () {
        const options = DedupeOptions(targetPath: '.');
        final cache = DedupeCacheManager(
          cacheDirPath: cacheDir,
          enabled: true,
          options: options,
        );

        // Add a valid cache entry
        const code = 'void testMethod() { print(1); }';
        final hash = DedupeCacheManager.computeContentHash(code);
        const extractor = AstExtractor(minTokens: 5, minLines: 1);
        final (seq, candidates) = extractor.extract(
          filePath: 'lib/sample.dart',
          content: code,
          fileIndex: 0,
        );
        cache.putEntry(
          relPath: 'lib/sample.dart',
          contentHash: hash,
          sequence: seq,
          candidates: candidates,
        );

        // Add unrelated files in the cache directory
        final configJson = File(p.join(cacheDir, 'config.json'));
        configJson.writeAsStringSync('{"settings": true}');

        final notesTxt = File(p.join(cacheDir, 'notes.txt'));
        notesTxt.writeAsStringSync('important notes');

        // Verify entry exists before clear
        check(
          cache.getEntry(relPath: 'lib/sample.dart', contentHash: hash),
        ).isNotNull();

        // Clear cache
        cache.clear();

        // Cache entry is gone
        check(
          cache.getEntry(relPath: 'lib/sample.dart', contentHash: hash),
        ).isNull();

        // Unrelated files remain untouched
        check(configJson.existsSync()).isTrue();
        check(notesTxt.existsSync()).isTrue();
      },
    );
    test('getEntry returns null on cache format version mismatch', () {
      const options = DedupeOptions(targetPath: '.');
      final cache = DedupeCacheManager(
        cacheDirPath: cacheDir,
        enabled: true,
        options: options,
      );

      const code = 'void testMethod() { print(1); }';
      final hash = DedupeCacheManager.computeContentHash(code);

      const extractor = AstExtractor(minTokens: 5, minLines: 1);
      final (seq, candidates) = extractor.extract(
        filePath: 'lib/sample.dart',
        content: code,
        fileIndex: 0,
      );

      cache.putEntry(
        relPath: 'lib/sample.dart',
        contentHash: hash,
        sequence: seq,
        candidates: candidates,
      );

      // Verify it is readable initially
      check(
        cache.getEntry(
          relPath: 'lib/sample.dart',
          contentHash: hash,
          fileIndex: 0,
        ),
      ).isNotNull();

      // Corrupt format version in cached file
      final pathHash = DedupeCacheManager.computeContentHash('lib/sample.dart');
      final cacheFile = File(
        p.join(cacheDir, pathHash.substring(0, 2), '$pathHash.json'),
      );
      final data =
          jsonDecode(cacheFile.readAsStringSync()) as Map<String, dynamic>;
      data['version'] = '999';
      cacheFile.writeAsStringSync(jsonEncode(data));

      final cached = cache.getEntry(
        relPath: 'lib/sample.dart',
        contentHash: hash,
        fileIndex: 0,
      );
      check(cached).isNull();
    });

    test(
      'getEntry returns null on SDK version or package version mismatch',
      () {
        const options = DedupeOptions(targetPath: '.');
        final cache = DedupeCacheManager(
          cacheDirPath: cacheDir,
          enabled: true,
          options: options,
          sdkVersion: '3.12.0',
          packageVersion: '0.1.0',
        );

        const code = 'void testMethod() { print(1); }';
        final hash = DedupeCacheManager.computeContentHash(code);

        const extractor = AstExtractor(minTokens: 5, minLines: 1);
        final (seq, candidates) = extractor.extract(
          filePath: 'lib/sample.dart',
          content: code,
          fileIndex: 0,
        );

        cache.putEntry(
          relPath: 'lib/sample.dart',
          contentHash: hash,
          sequence: seq,
          candidates: candidates,
        );

        final diffSdkCache = DedupeCacheManager(
          cacheDirPath: cacheDir,
          enabled: true,
          options: options,
          sdkVersion: '3.13.0',
          packageVersion: '0.1.0',
        );
        check(
          diffSdkCache.getEntry(
            relPath: 'lib/sample.dart',
            contentHash: hash,
            fileIndex: 0,
          ),
        ).isNull();

        final diffPkgCache = DedupeCacheManager(
          cacheDirPath: cacheDir,
          enabled: true,
          options: options,
          sdkVersion: '3.12.0',
          packageVersion: '0.2.0',
        );
        check(
          diffPkgCache.getEntry(
            relPath: 'lib/sample.dart',
            contentHash: hash,
            fileIndex: 0,
          ),
        ).isNull();

        final sameCache = DedupeCacheManager(
          cacheDirPath: cacheDir,
          enabled: true,
          options: options,
          sdkVersion: '3.12.0',
          packageVersion: '0.1.0',
        );
        check(
          sameCache.getEntry(
            relPath: 'lib/sample.dart',
            contentHash: hash,
            fileIndex: 0,
          ),
        ).isNotNull();
      },
    );

    test(
      'getEntry gracefully handles corrupt or truncated JSON cache files',
      () {
        const options = DedupeOptions(targetPath: '.');
        final cache = DedupeCacheManager(
          cacheDirPath: cacheDir,
          enabled: true,
          options: options,
        );

        const code = 'void testMethod() { print(1); }';
        final hash = DedupeCacheManager.computeContentHash(code);

        const extractor = AstExtractor(minTokens: 5, minLines: 1);
        final (seq, candidates) = extractor.extract(
          filePath: 'lib/sample.dart',
          content: code,
          fileIndex: 0,
        );

        cache.putEntry(
          relPath: 'lib/sample.dart',
          contentHash: hash,
          sequence: seq,
          candidates: candidates,
        );

        final pathHash = DedupeCacheManager.computeContentHash(
          'lib/sample.dart',
        );
        final cacheFile = File(
          p.join(cacheDir, pathHash.substring(0, 2), '$pathHash.json'),
        );

        // Truncated JSON
        cacheFile.writeAsStringSync(
          '{"version": "1", "relPath": "lib/sample.da',
        );
        check(
          cache.getEntry(
            relPath: 'lib/sample.dart',
            contentHash: hash,
            fileIndex: 0,
          ),
        ).isNull();

        // Completely non-JSON data
        cacheFile.writeAsStringSync('not json content at all');
        check(
          cache.getEntry(
            relPath: 'lib/sample.dart',
            contentHash: hash,
            fileIndex: 0,
          ),
        ).isNull();

        // JSON array instead of map
        cacheFile.writeAsStringSync('[1, 2, 3]');
        check(
          cache.getEntry(
            relPath: 'lib/sample.dart',
            contentHash: hash,
            fileIndex: 0,
          ),
        ).isNull();
      },
    );

    test('getEntry returns null when relPath mismatches', () {
      const options = DedupeOptions(targetPath: '.');
      final cache = DedupeCacheManager(
        cacheDirPath: cacheDir,
        enabled: true,
        options: options,
      );

      const code = 'void testMethod() { print(1); }';
      final hash = DedupeCacheManager.computeContentHash(code);

      const extractor = AstExtractor(minTokens: 5, minLines: 1);
      final (seq, candidates) = extractor.extract(
        filePath: 'lib/sample.dart',
        content: code,
        fileIndex: 0,
      );

      cache.putEntry(
        relPath: 'lib/sample.dart',
        contentHash: hash,
        sequence: seq,
        candidates: candidates,
      );

      // Mismatch relPath payload
      final pathHash = DedupeCacheManager.computeContentHash('lib/sample.dart');
      final cacheFile = File(
        p.join(cacheDir, pathHash.substring(0, 2), '$pathHash.json'),
      );
      final data =
          jsonDecode(cacheFile.readAsStringSync()) as Map<String, dynamic>;
      data['relPath'] = 'lib/colliding_other.dart';
      cacheFile.writeAsStringSync(jsonEncode(data));

      final cached = cache.getEntry(
        relPath: 'lib/sample.dart',
        contentHash: hash,
        fileIndex: 0,
      );
      check(cached).isNull();
    });
  });

  group('DedupeEngine Incremental Cache Integration', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync(
        'dedupe_engine_cache_test_',
      );
      Directory(p.join(tempDir.path, 'lib')).createSync(recursive: true);
      File(p.join(tempDir.path, 'lib', 'a.dart')).writeAsStringSync('''
void duplicateFunctionA() {
  print('Line 1');
  print('Line 2');
  print('Line 3');
  print('Line 4');
}
''');
      File(p.join(tempDir.path, 'lib', 'b.dart')).writeAsStringSync('''
void duplicateFunctionB() {
  print('Line 1');
  print('Line 2');
  print('Line 3');
  print('Line 4');
}
''');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
      'caches extraction results and hits cache on subsequent analysis',
      () async {
        final cacheDir = p.join(tempDir.path, '.cache');
        final options = DedupeOptions(
          targetPath: tempDir.path,
          minTokens: 10,
          minLines: 3,
          useCache: true,
          cacheDir: cacheDir,
        );

        final engine1 = DedupeEngine(options);
        final report1 = await engine1.analyze();
        check(report1.summary.clusterCount).isGreaterThan(0);
        check(Directory(cacheDir).existsSync()).equals(true);

        // Second run hits the cache
        final engine2 = DedupeEngine(options);
        final report2 = await engine2.analyze();
        check(
          report2.summary.clusterCount,
        ).equals(report1.summary.clusterCount);
        check(
          report2.summary.duplicateLines,
        ).equals(report1.summary.duplicateLines);
      },
    );

    test('clearCache option clears existing cache directory', () async {
      final cacheDir = p.join(tempDir.path, '.cache');
      final options1 = DedupeOptions(
        targetPath: tempDir.path,
        minTokens: 10,
        minLines: 3,
        useCache: true,
        cacheDir: cacheDir,
      );

      final engine1 = DedupeEngine(options1);
      await engine1.analyze();
      final cacheFiles1 = Directory(
        cacheDir,
      ).listSync(recursive: true).whereType<File>().toList();
      check(cacheFiles1).isNotEmpty();

      final options2 = DedupeOptions(
        targetPath: tempDir.path,
        minTokens: 10,
        minLines: 3,
        useCache: false,
        clearCache: true,
        cacheDir: cacheDir,
      );

      final engine2 = DedupeEngine(options2);
      await engine2.analyze();
      final cacheFiles2 = Directory(
        cacheDir,
      ).listSync(recursive: true).whereType<File>().toList();
      check(cacheFiles2).isEmpty();
    });

    test('verifies real cache hit by poisoning a cached entry', () async {
      final cacheDir = p.join(tempDir.path, '.cache');
      final options = DedupeOptions(
        targetPath: tempDir.path,
        minTokens: 10,
        minLines: 3,
        useCache: true,
        cacheDir: cacheDir,
      );

      final engine1 = DedupeEngine(options);
      final report1 = await engine1.analyze();
      check(report1.summary.clusterCount).equals(1);

      // Poison the cache entry for lib/b.dart to have 0 tokens and 0 candidates
      final pathHash = DedupeCacheManager.computeContentHash('lib/b.dart');
      final cacheFile = File(
        p.join(cacheDir, pathHash.substring(0, 2), '$pathHash.json'),
      );
      check(cacheFile.existsSync()).isTrue();

      final data =
          jsonDecode(cacheFile.readAsStringSync()) as Map<String, dynamic>;
      final entry = data['entry'] as Map<String, dynamic>;
      entry['tokens'] = <dynamic>[];
      entry['candidates'] = <dynamic>[];
      cacheFile.writeAsStringSync(jsonEncode(data));

      // Re-run analysis; because lib/b.dart was poisoned in the cache, no clusters are found
      final engine2 = DedupeEngine(options);
      final report2 = await engine2.analyze();
      check(report2.summary.clusterCount).equals(0);
    });

    test('cached run vs --no-cache run produce identical reports', () async {
      final cacheDir = p.join(tempDir.path, '.cache');
      final cachedOptions = DedupeOptions(
        targetPath: tempDir.path,
        minTokens: 10,
        minLines: 3,
        useCache: true,
        cacheDir: cacheDir,
      );
      final noCacheOptions = DedupeOptions(
        targetPath: tempDir.path,
        minTokens: 10,
        minLines: 3,
        useCache: false,
      );

      // First run populates cache
      await DedupeEngine(cachedOptions).analyze();

      // Second run hits cache
      final cachedReport = await DedupeEngine(cachedOptions).analyze();
      final noCacheReport = await DedupeEngine(noCacheOptions).analyze();

      check(cachedReport.toJson()).deepEquals(noCacheReport.toJson());
    });
  });
}
