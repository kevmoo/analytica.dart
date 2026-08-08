import 'dart:convert';
import 'package:checks/checks.dart';
import 'package:test/scaffolding.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;
import 'package:test_process/test_process.dart';

void main() {
  group('DataFlow CLI Integration', () {
    test('Displays usage help and exits with code 0 on --help', () async {
      final proc = await TestProcess.start('dart', [
        'run',
        'bin/data_flow.dart',
        '--help',
      ]);

      final stdout = await proc.stdoutStream().join('\n');
      await proc.shouldExit(0);

      check(stdout).contains('Dart Data-Flow & Method Extraction Analyzer');
      check(stdout).contains('Usage:');
      check(stdout).contains('--lines');
    });

    test('Exits with code 64 when no target file is provided', () async {
      final proc = await TestProcess.start('dart', [
        'run',
        'bin/data_flow.dart',
      ]);

      final stderr = await proc.stderrStream().join('\n');
      await proc.shouldExit(64);

      check(stderr).contains('Error: Missing target file.');
    });

    test('Analyzes target slice and outputs JSON by default', () async {
      await d.dir('project', [
        d.file('sample.dart', '''
void runFlow(String token) {
  int retries = 0;
  // Lines 4-6
  retries += 1;
  final isValid = token.isNotEmpty;
  // Line 8
  print('\$isValid \$retries');
}
'''),
      ]).create();

      final proc = await TestProcess.start('dart', [
        'run',
        'bin/data_flow.dart',
        '${d.sandbox}/project/sample.dart:4-6',
      ]);

      final stdout = await proc.stdoutStream().join('\n');
      await proc.shouldExit(0);

      final jsonMap = jsonDecode(stdout) as Map<String, dynamic>;
      check(jsonMap['enclosing']).equals('runFlow');
      check(jsonMap['startLine']).equals(4);
      check(jsonMap['endLine']).equals(6);
      check(jsonMap['isCleanlyExtractable']).equals(true);
      check(
        jsonMap['suggestedSignature'] as String,
      ).contains('({bool isValid, int retries})');
    });

    test(
      'Outputs formatted text report when --format=text requested',
      () async {
        await d.dir('project2', [
          d.file('sample2.dart', '''
void process(int a, int b) {
  // Lines 3-4
  final sum = a + b;
  // Line 6
  print(sum);
}
'''),
        ]).create();

        final proc = await TestProcess.start('dart', [
          'run',
          'bin/data_flow.dart',
          '--format=text',
          '--name=_add',
          '--lines=3-4',
          '${d.sandbox}/project2/sample2.dart',
        ]);

        final stdout = await proc.stdoutStream().join('\n');
        await proc.shouldExit(0);

        check(stdout).contains('Data-Flow Extraction Analysis:');
        check(stdout).contains('Inbound Parameters (Inputs):');
        check(stdout).contains('int a (read-only)');
        check(stdout).contains('int b (read-only)');
        check(stdout).contains('Outbound Returns (Outputs):');
        check(stdout).contains('int sum');
        check(stdout).contains('Suggested Signature:');
        check(stdout).contains('int _add(int a, int b)');
        check(stdout).contains('Status: ✅ Cleanly Extractable');
      },
    );
  });
}
