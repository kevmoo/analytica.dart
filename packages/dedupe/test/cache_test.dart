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
  });
}
