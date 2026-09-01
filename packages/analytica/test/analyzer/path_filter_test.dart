import 'package:analytica/analyzer.dart';
import 'package:checks/checks.dart';
import 'package:glob/glob.dart';
import 'package:test/scaffolding.dart';

void main() {
  group('PathFilter', () {
    test('defaults exclude standard build and metadata directories', () {
      final filter = PathFilter.defaults;

      check(filter.isExcluded('.dart_tool/package_config.json')).isTrue();
      check(filter.isExcluded('.git/HEAD')).isTrue();
      check(filter.isExcluded('.idea/workspace.xml')).isTrue();
      check(filter.isExcluded('.vscode/settings.json')).isTrue();
      check(filter.isExcluded('build/app/outputs')).isTrue();
      check(filter.isExcluded('build/flutter_assets/foo.png')).isTrue();

      check(filter.isExcluded('lib/src/build/builder.dart')).isFalse();
      check(filter.isExcluded('lib/builders/code_builder.dart')).isFalse();
      check(filter.isExcluded('.github/workflows/ci.yml')).isFalse();
      check(filter.isExcluded('lib/src/service.dart')).isFalse();
    });

    test('defaults exclude generated Dart files', () {
      final filter = PathFilter.defaults;

      check(filter.isExcluded('lib/src/model.g.dart')).isTrue();
      check(filter.isExcluded('lib/src/model.freezed.dart')).isTrue();
      check(filter.isExcluded('test/service.mocks.dart')).isTrue();
      check(filter.isExcluded('lib/di.config.dart')).isTrue();
      check(filter.isExcluded('lib/generated.reflectable.dart')).isTrue();
      check(filter.isExcluded('lib/schema.pb.dart')).isTrue();
      check(filter.isExcluded('lib/schema.pbenum.dart')).isTrue();
      check(filter.isExcluded('lib/schema.pbjson.dart')).isTrue();
      check(filter.isExcluded('lib/schema.pbserver.dart')).isTrue();

      check(filter.isExcluded('lib/src/model.dart')).isFalse();
      check(filter.isExcluded('lib/generator.dart')).isFalse();
    });

    test('ignoreGenerated: false includes generated files', () {
      final filter = PathFilter(ignoreGenerated: false);

      check(filter.isExcluded('lib/src/model.g.dart')).isFalse();
      check(filter.isExcluded('lib/src/model.freezed.dart')).isFalse();
      check(filter.isExcluded('test/service.mocks.dart')).isFalse();

      // Still excludes standard tool directories
      check(filter.isExcluded('.dart_tool/package_config.json')).isTrue();
      check(filter.isExcluded('.git/HEAD')).isTrue();
      check(filter.isExcluded('build/output.dart')).isTrue();
    });

    test('custom excludePatterns match specific globs and prefixes', () {
      final filter = PathFilter(
        excludePatterns: ['test/fixtures/**', 'legacy_*.dart'],
      );

      check(filter.isExcluded('test/fixtures/sample.dart')).isTrue();
      check(filter.isExcluded('lib/src/legacy_parser.dart')).isTrue();
      check(filter.isExcluded('lib/src/regular_parser.dart')).isFalse();
    });

    test('normalizes leading ./, /, and backslashes', () {
      final filter = PathFilter(excludePatterns: ['/custom/**', './other/**']);

      check(filter.isExcluded(r'.\custom\sub\file.dart')).isTrue();
      check(filter.isExcluded('./custom/sub/file.dart')).isTrue();
      check(filter.isExcluded('/custom/sub/file.dart')).isTrue();
      check(filter.isExcluded('custom/sub/file.dart')).isTrue();
      check(filter.isExcluded('other/sub/file.dart')).isTrue();
      check(filter.isExcluded(r'lib\src\model.g.dart')).isTrue();
    });
  });

  group('PathFilter glob syntax', () {
    test('supports brace expansion', () {
      final filter = PathFilter(
        excludePatterns: ['**/*.{g,freezed}.dart'],
        ignoreGenerated: false,
      );

      check(filter.isExcluded('lib/src/model.g.dart')).isTrue();
      check(filter.isExcluded('lib/src/model.freezed.dart')).isTrue();
      check(filter.isExcluded('model.g.dart')).isTrue();
      check(filter.isExcluded('lib/src/model.dart')).isFalse();
    });

    test('supports character classes', () {
      final filter = PathFilter(
        excludePatterns: ['**/*_[0-9].dart'],
        ignoreGenerated: false,
      );

      check(filter.isExcluded('lib/part_3.dart')).isTrue();
      check(filter.isExcluded('part_0.dart')).isTrue();
      check(filter.isExcluded('lib/part_x.dart')).isFalse();
    });

    test('Glob.quote escapes a metacharacter back to a literal', () {
      // The documented migration path for the literal -> metacharacter break.
      final filter = PathFilter(
        excludePatterns: [Glob.quote('lib/a[0].dart')],
        ignoreGenerated: false,
      );

      check(filter.isExcluded('lib/a[0].dart')).isTrue();
      check(filter.isExcluded('lib/a0.dart')).isFalse();
    });

    test('a backslash in a pattern escapes, it does not separate', () {
      // Only candidate paths are normalized from Windows separators.
      final filter = PathFilter(
        excludePatterns: [r'lib/a\{b.dart'],
        ignoreGenerated: false,
      );

      check(filter.isExcluded('lib/a{b.dart')).isTrue();
      check(filter.isExcluded(r'lib\a{b.dart')).isTrue();
    });

    test('consecutive ** segments still match at the root', () {
      final filter = PathFilter(
        excludePatterns: ['**/**/x.dart'],
        ignoreGenerated: false,
      );

      check(filter.isExcluded('x.dart')).isTrue();
      check(filter.isExcluded('lib/x.dart')).isTrue();
      check(filter.isExcluded('a/b/x.dart')).isTrue();
      check(filter.isExcluded('lib/y.dart')).isFalse();
    });

    test('rejects a malformed pattern, naming the pattern', () {
      // The previous matcher escaped anything it did not understand, so a
      // typo silently matched nothing for the life of the process.
      check(
          () => PathFilter(excludePatterns: ['lib/[unclosed']),
        ).throws<FormatException>().has((e) => e.message, 'message')
        ..contains('lib/[unclosed')
        ..contains('Invalid exclude pattern');
    });
  });
}
