import 'dart:io';

import 'package:analytica/analyzer.dart';
import 'package:checks/checks.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('defaultDartExclusions', () {
    test('contains expected standard exclusion patterns', () {
      check(defaultDartExclusions).contains('**/*.g.dart');
      check(defaultDartExclusions).contains('**/*.freezed.dart');
      check(defaultDartExclusions).contains('**/*.pb.dart');
      check(defaultDartExclusions).contains('**/*.mocks.dart');
      check(defaultDartExclusions).contains('**/*_bindings.dart');
    });
  });

  group('discoverDartFiles', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync(
        'analytica_discovery_test_',
      );
      Directory(p.join(tempDir.path, 'lib', 'src')).createSync(recursive: true);
      Directory(p.join(tempDir.path, 'test')).createSync(recursive: true);

      File(
        p.join(tempDir.path, 'lib', 'main.dart'),
      ).writeAsStringSync('void main() {}');
      File(
        p.join(tempDir.path, 'lib', 'src', 'util.dart'),
      ).writeAsStringSync('void util() {}');
      File(
        p.join(tempDir.path, 'lib', 'src', 'util.g.dart'),
      ).writeAsStringSync('// generated');
      File(
        p.join(tempDir.path, 'lib', 'src', 'native_bindings.dart'),
      ).writeAsStringSync('// native');
      File(
        p.join(tempDir.path, 'test', 'main_test.dart'),
      ).writeAsStringSync('void main() {}');
      File(p.join(tempDir.path, 'README.md')).writeAsStringSync('# Readme');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('returns empty list for nonexistent directory', () {
      final files = discoverDartFiles(p.join(tempDir.path, 'nonexistent'));
      check(files).isEmpty();
    });

    test('discovers all dart files excluding default generated code', () {
      final files = discoverDartFiles(tempDir.path);
      final relativeFiles = files
          .map((f) => p.relative(f, from: tempDir.path))
          .toList();

      check(relativeFiles).contains(p.join('lib', 'main.dart'));
      check(relativeFiles).contains(p.join('lib', 'src', 'util.dart'));
      check(relativeFiles).contains(p.join('test', 'main_test.dart'));

      // Excluded files
      check(
        relativeFiles,
      ).not((r) => r.contains(p.join('lib', 'src', 'util.g.dart')));
      check(
        relativeFiles,
      ).not((r) => r.contains(p.join('lib', 'src', 'native_bindings.dart')));
      check(relativeFiles).not((r) => r.contains('README.md'));
    });

    test('respects specific targets parameter', () {
      final files = discoverDartFiles(tempDir.path, targets: ['lib']);
      final relativeFiles = files
          .map((f) => p.relative(f, from: tempDir.path))
          .toList();

      check(relativeFiles).contains(p.join('lib', 'main.dart'));
      check(relativeFiles).contains(p.join('lib', 'src', 'util.dart'));
      check(
        relativeFiles,
      ).not((r) => r.contains(p.join('test', 'main_test.dart')));
    });

    test('handles single file target', () {
      final files = discoverDartFiles(
        tempDir.path,
        targets: [p.join('lib', 'main.dart')],
      );
      final relativeFiles = files
          .map((f) => p.relative(f, from: tempDir.path))
          .toList();

      check(relativeFiles).length.equals(1);
      check(relativeFiles.first).equals(p.join('lib', 'main.dart'));
    });

    test('respects custom exclude patterns', () {
      final files = discoverDartFiles(
        tempDir.path,
        excludePatterns: ['**/test/**'],
      );
      final relativeFiles = files
          .map((f) => p.relative(f, from: tempDir.path))
          .toList();

      check(relativeFiles).contains(p.join('lib', 'main.dart'));
      check(
        relativeFiles,
      ).not((r) => r.contains(p.join('test', 'main_test.dart')));
    });

    test('respects custom include patterns', () {
      final files = discoverDartFiles(
        tempDir.path,
        includePatterns: ['**/util.dart'],
      );
      final relativeFiles = files
          .map((f) => p.relative(f, from: tempDir.path))
          .toList();

      check(relativeFiles).length.equals(1);
      check(relativeFiles.first).equals(p.join('lib', 'src', 'util.dart'));
    });
  });
}
