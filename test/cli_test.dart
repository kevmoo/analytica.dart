import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;
import 'package:test_process/test_process.dart';

void main() {
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

      final process = await TestProcess.start('dart', [
        'run',
        'bin/cognitive_complexity.dart',
        '${d.sandbox}/project',
      ]);

      await expectLater(
        process.stdout,
        emitsThrough(contains('Score  Declaration')),
      );
      await expectLater(process.stdout, emitsThrough(contains('3  compute')));
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

        final process = await TestProcess.start('dart', [
          'run',
          'bin/cognitive_complexity.dart',
          '--format',
          'json',
          '${d.sandbox}/project_json',
        ]);

        await expectLater(
          process.stdout,
          emitsThrough(
            allOf(contains('"name":"MyService.handle"'), contains('"score":1')),
          ),
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

      final process = await TestProcess.start('dart', [
        'run',
        'bin/cognitive_complexity.dart',
        '--fail-threshold',
        '2',
        '${d.sandbox}/project_fail',
      ]);

      await expectLater(process.stdout, emitsThrough(contains('[VIOLATION]')));
      await expectLater(
        process.stderr,
        emitsThrough(contains('exceeded the failure threshold (2)')),
      );
      await process.shouldExit(1);
    });
  });
}
