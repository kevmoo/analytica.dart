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

    test('resolvePackageFile locates pubspec.yaml', () async {
      final file = await resolvePackageFile(
        'package:analytica/analytica.dart',
        'pubspec.yaml',
      );
      check(file.existsSync()).isTrue();
      check(file.readAsStringSync()).contains('name: analytica');
    });

    test('resolvePackageExecutable locates executable in bin/', () async {
      final binPath = await resolvePackageExecutable(
        'package:cognitive_complexity/cognitive_complexity.dart',
      );
      check(binPath).endsWith('bin/cognitive_complexity.dart');

      final dataFlowBin = await resolvePackageExecutable(
        'package:cognitive_complexity/cognitive_complexity.dart',
        'data_flow',
      );
      check(dataFlowBin).endsWith('bin/data_flow.dart');
    });

    test('throws ArgumentError on non-package URI', () async {
      await check(
        resolvePackageDirectory('file:///foo/bar.dart'),
      ).throws<ArgumentError>();
    });
  });
}
