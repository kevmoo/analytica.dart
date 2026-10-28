import 'package:analytica/analytica.dart';
import 'package:analytica/analyzer.dart';
import 'package:checks/checks.dart';
import 'package:path/path.dart' as p;
import 'package:test/scaffolding.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

void main() {
  group('AnalysisContextHelper', () {
    late String pkgDir;

    setUp(() async {
      await d.dir('test_pkg', [
        d.file('pubspec.yaml', '''
name: test_pkg
environment:
  sdk: '^3.12.0'
'''),
        d.dir('lib', [
          d.file('foo.dart', '''
class Foo {
  final int val;
  const Foo(this.val);
}
'''),
        ]),
      ]).create();

      pkgDir = p.join(d.sandbox, 'test_pkg');
    });

    test('initializes and resolves Dart source files', () async {
      final helper = AnalysisContextHelper(includedPaths: [pkgDir]);
      final filePath = p.join(pkgDir, 'lib', 'foo.dart');

      final result = await helper.getResolvedUnit(filePath);
      check(result).isNotNull();
      check(result!.exists).isTrue();
      check(result.unit.declarations.length).equals(1);

      final reqResult = await helper.getRequiredResolvedUnit(filePath);
      check(reqResult.unit.declarations.length).equals(1);
    });

    test('static resolveFile resolves a file directly', () async {
      final filePath = p.join(pkgDir, 'lib', 'foo.dart');
      final result = await AnalysisContextHelper.resolveFile(filePath);
      check(result.unit.declarations.length).equals(1);
    });

    test('returns null for non-existent file in getResolvedUnit', () async {
      final helper = AnalysisContextHelper(includedPaths: [pkgDir]);
      final missingPath = p.join(pkgDir, 'lib', 'missing.dart');

      final result = await helper.getResolvedUnit(missingPath);
      check(result).isNull();

      await check(
        helper.getRequiredResolvedUnit(missingPath),
      ).throws<StateError>();
    });

    test('safely returns null for paths outside analysis context in '
        'getResolvedUnit', () async {
      final helper = AnalysisContextHelper(includedPaths: [pkgDir]);
      const outsidePath = '/tmp/completely_outside.dart';

      final result = await helper.getResolvedUnit(outsidePath);
      check(result).isNull();
    });

    test('throws ArgumentError on empty includedPaths', () {
      check(
        () => AnalysisContextHelper(includedPaths: []),
      ).throws<ArgumentError>();
    });

    test('throws SdkDiscoveryException on invalid sdkPath', () {
      check(
        () => AnalysisContextHelper(
          includedPaths: [pkgDir],
          sdkPath: '/non/existent/sdk',
        ),
      ).throws<SdkDiscoveryException>();
    });
  });
}
