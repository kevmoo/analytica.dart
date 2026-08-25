import 'dart:io';

import 'package:checks/checks.dart';
import 'package:cognitive_complexity/cognitive_complexity.dart';
import 'package:path/path.dart' as p;
import 'package:test/scaffolding.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

void main() {
  group('ComplexityAnalyzer path filtering', () {
    test('skips generated Dart files by default', () async {
      final dir = p.join(d.sandbox, 'gen_project');
      final libDir = Directory(p.join(dir, 'lib'))..createSync(recursive: true);

      File(p.join(libDir.path, 'model.dart')).writeAsStringSync('''
int normalFunction(int x) {
  if (x > 0) {
    for (var i = 0; i < x; i++) {
      if (i % 2 == 0) return i;
    }
  }
  return 0;
}
''');

      File(p.join(libDir.path, 'model.g.dart')).writeAsStringSync('''
int generatedFunction(int x) {
  if (x > 0) {
    for (var i = 0; i < x; i++) {
      if (i % 2 == 0) return i;
    }
  }
  return 0;
}
''');

      final analyzer = ComplexityAnalyzer();
      final results = analyzer.analyzePath(dir);

      check(results).length.equals(1);
      check(results.first.name).equals('normalFunction');
    });

    test('analyzes generated files when ignoreGenerated: false', () async {
      final dir = p.join(d.sandbox, 'gen_project_all');
      final libDir = Directory(p.join(dir, 'lib'))..createSync(recursive: true);

      File(
        p.join(libDir.path, 'model.dart'),
      ).writeAsStringSync('int a() => 1;');
      File(
        p.join(libDir.path, 'model.g.dart'),
      ).writeAsStringSync('int b() => 2;');

      final analyzer = ComplexityAnalyzer(
        pathFilter: PathFilter(ignoreGenerated: false),
      );
      final results = analyzer.analyzePath(dir);

      check(results).length.equals(2);
    });

    test('custom excludePatterns skips matching files', () async {
      final dir = p.join(d.sandbox, 'custom_project');
      final libDir = Directory(p.join(dir, 'lib'))..createSync(recursive: true);

      File(
        p.join(libDir.path, 'legacy_auth.dart'),
      ).writeAsStringSync('int a() => 1;');
      File(
        p.join(libDir.path, 'new_auth.dart'),
      ).writeAsStringSync('int b() => 2;');

      final analyzer = ComplexityAnalyzer(
        pathFilter: PathFilter(excludePatterns: ['**/legacy_*']),
      );
      final results = analyzer.analyzePath(dir);

      check(results).length.equals(1);
      check(results.first.name).equals('b');
    });
  });
}
