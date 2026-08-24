import 'package:analytica/testing.dart';
import 'package:checks/checks.dart';
import 'package:test/test.dart';

void main() {
  group('package_resolution', () {
    test('resolvePackageDirectory resolves package:analytica', () async {
      final dir = await resolvePackageDirectory(
        'package:analytica/analytica.dart',
      );
      check(dir).endsWith('packages/analytica');
    });

    test('resolvePackageDirectory handles multi-segment URIs', () async {
      final dir = await resolvePackageDirectory(
        'package:analytica/src/testing/package_resolution.dart',
      );
      check(dir).endsWith('packages/analytica');
    });

    test('resolvePackageFile locates pubspec.yaml', () async {
      final file = await resolvePackageFile(
        'package:analytica/analytica.dart',
        'pubspec.yaml',
      );
      check(file.existsSync()).isTrue();
      check(file.readAsStringSync()).contains('name: analytica');
    });

    test(
      'resolvePackageExecutable throws StateError when executable is missing',
      () async {
        await check(
          resolvePackageExecutable(
            'package:analytica/analytica.dart',
            'nonexistent_cli',
          ),
        ).throws<StateError>();
      },
    );

    test('throws ArgumentError on non-package URI', () async {
      await check(
        resolvePackageDirectory('file:///foo/bar.dart'),
      ).throws<ArgumentError>();
    });
  });
}
