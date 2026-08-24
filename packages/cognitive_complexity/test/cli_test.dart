import 'dart:io';

import 'package:analytica/testing.dart';
import 'package:checks/checks.dart';
import 'package:test/scaffolding.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;
import 'package:test_process/test_process.dart';

void main() {
  late String binPath;

  setUpAll(() async {
    binPath = await resolvePackageExecutable(
      'package:cognitive_complexity/cognitive_complexity.dart',
    );
  });

  group('CLI Integration Tests', () {
    test('Calculates complexity and displays text table report', () async {
      await d.dir('project', [
        d.dir('lib', [
          d.file('sample.dart', '''
int compute(int x) {
  if (x > 0) {
    if (x > 10) {
      return 2;
    }
    return 1;
  }
  return 0;
}
'''),
        ]),
      ]).create();

      final process = await TestProcess.start(Platform.resolvedExecutable, [
        binPath,
        '${d.sandbox}/project',
      ]);

      await check(
        process.stdout,
      ).emitsThrough((s) => s.contains('Score  Declaration'));
      await check(process.stdout).emitsThrough((s) => s.contains('3  compute'));
      await process.shouldExit(0);
    });

    test(
      'Outputs clean JSON formatted array when --format json is requested',
      () async {
        await d.dir('project_json', [
          d.dir('lib', [
            d.file('service.dart', '''
class MyService {
  void handle(bool flag) {
    if (flag) {
      print('ok');
    }
  }
}
'''),
          ]),
        ]).create();

        final process = await TestProcess.start(Platform.resolvedExecutable, [
          binPath,
          '--format',
          'json',
          '${d.sandbox}/project_json',
        ]);

        await check(process.stdout).emitsThrough(
          (s) => s
            ..contains('"name":"MyService.handle"')
            ..contains('"score":1'),
        );
        await process.shouldExit(0);
      },
    );

    test('Exits with code 1 when --fail-threshold is exceeded', () async {
      await d.dir('project_fail', [
        d.dir('lib', [
          d.file('bad_func.dart', '''
void complexFunc(int a) {
  if (a > 1) {
    if (a > 2) {
      if (a > 3) {
        print(a);
      }
    }
  }
}
'''),
        ]),
      ]).create();

      final process = await TestProcess.start(Platform.resolvedExecutable, [
        binPath,
        '--fail-threshold',
        '2',
        '${d.sandbox}/project_fail',
      ]);

      await check(
        process.stdout,
      ).emitsThrough((s) => s.contains('[VIOLATION]'));
      await check(
        process.stderr,
      ).emitsThrough((s) => s.contains('exceeded the failure threshold (2)'));
      await process.shouldExit(1);
    });
  });
}
