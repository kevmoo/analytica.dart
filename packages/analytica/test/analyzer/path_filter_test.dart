import 'package:analytica/analyzer.dart';
import 'package:checks/checks.dart';
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
}
