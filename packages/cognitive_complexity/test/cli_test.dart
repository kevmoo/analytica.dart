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

    test('Supports opt-in --max-file-lines and --max-function-lines across '
        'text, json, and github formats', () async {
      final generatedBody = List.generate(
        25,
        (i) => '  final x$i = $i;',
      ).join('\n');
      await d.dir('project_lines', [
        d.dir('lib', [
          d.file('long_file.dart', 'void bigDecl() {\n$generatedBody\n}\n'),
        ]),
      ]).create();

      final target = '${d.sandbox}/project_lines/lib/long_file.dart';

      // 1. Default run (limits disabled) exits 0 and JSON is a bare list
      final defaultJsonProc = await TestProcess.start(
        Platform.resolvedExecutable,
        [binPath, '--format', 'json', target],
      );
      final defaultJsonLine = await defaultJsonProc.stdout.next;
      check(defaultJsonLine.startsWith('[')).isTrue();
      await defaultJsonProc.shouldExit(0);

      // 2. --max-file-lines in JSON format emits declarations + files object
      final fileJsonProc = await TestProcess.start(
        Platform.resolvedExecutable,
        [binPath, '--max-file-lines', '15', '--format', 'json', target],
      );
      final fileJsonLine = await fileJsonProc.stdout.next;
      check(fileJsonLine)
        ..contains('"declarations":')
        ..contains('"files":')
        ..contains('"violation":true');
      await fileJsonProc.shouldExit(1);

      // 3. --max-file-lines and --max-function-lines in github format
      final ghProc = await TestProcess.start(Platform.resolvedExecutable, [
        binPath,
        '--max-file-lines',
        '15',
        '--max-function-lines',
        '15',
        '--format',
        'github',
        target,
      ]);
      await check(ghProc.stdout).emitsThrough(
        (s) => s.contains('title=Declaration Line Limit Exceeded'),
      );
      await check(
        ghProc.stdout,
      ).emitsThrough((s) => s.contains('title=File Line Limit Exceeded'));
      await ghProc.shouldExit(1);
    });
  });
}
