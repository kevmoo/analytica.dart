import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:path/path.dart' as p;
import 'package:test/scaffolding.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;
import 'package:test_process/test_process.dart';

void main() {
  // Pin subprocesses to the SDK running the tests rather than PATH's `dart`.
  final dartExe = Platform.resolvedExecutable;

  group('DataFlow CLI Integration', () {
    test('Displays usage help and exits with code 0 on --help', () async {
      final proc = await TestProcess.start(dartExe, [
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
      final proc = await TestProcess.start(dartExe, [
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

      final proc = await TestProcess.start(dartExe, [
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

        final proc = await TestProcess.start(dartExe, [
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

    test('Parses target path with Windows-style drive colon syntax', () async {
      await d.dir('project3', [
        d.file('sample3.dart', '''
void process(int a) {
  // Lines 3-4
  final b = a * 10;
  print(b);
}
'''),
      ]).create();

      // Test with drive-like prefix pattern
      final samplePath = '${d.sandbox}/project3/sample3.dart';
      final proc = await TestProcess.start(dartExe, [
        'run',
        'bin/data_flow.dart',
        '$samplePath:3-4',
      ]);

      final stdout = await proc.stdoutStream().join('\n');
      await proc.shouldExit(0);

      final jsonMap = jsonDecode(stdout) as Map<String, dynamic>;
      check(jsonMap['enclosing']).equals('process');
      check(jsonMap['startLine']).equals(3);
      check(jsonMap['endLine']).equals(4);
    });
  });

  group('SDK path resolution', () {
    test('Documents --sdk-path and DART_SDK in help text', () async {
      final proc = await TestProcess.start(dartExe, [
        'run',
        'bin/data_flow.dart',
        '--help',
      ]);

      final stdout = await proc.stdoutStream().join('\n');
      await proc.shouldExit(0);

      check(stdout).contains('--sdk-path');
      check(stdout).contains('DART_SDK');
    });

    test('Exits with config error for an invalid --sdk-path', () async {
      await d.dir('proj', [d.file('sample.dart', 'void main() {}\n')]).create();

      final proc = await TestProcess.start(dartExe, [
        'run',
        'bin/data_flow.dart',
        '--sdk-path',
        '${d.sandbox}/proj',
        '${d.sandbox}/proj/sample.dart:1-1',
      ]);

      final stderr = await proc.stderrStream().join('\n');
      await proc.shouldExit(78);

      check(stderr).contains('does not point to a valid Dart SDK root');
    });

    test('Analyzes successfully with an explicit valid --sdk-path', () async {
      await d.dir('proj2', [
        d.file('sample.dart', '''
void process(int a) {
  // Line 3
  final b = a * 10;
  print(b);
}
'''),
      ]).create();

      final sdkRoot = p.dirname(p.dirname(Platform.resolvedExecutable));
      final proc = await TestProcess.start(dartExe, [
        'run',
        'bin/data_flow.dart',
        '--sdk-path',
        sdkRoot,
        '${d.sandbox}/proj2/sample.dart:3-3',
      ]);

      final stdout = await proc.stdoutStream().join('\n');
      await proc.shouldExit(0);

      final jsonMap = jsonDecode(stdout) as Map<String, dynamic>;
      check(jsonMap['enclosing']).equals('process');
      check(jsonMap['isCleanlyExtractable']).equals(true);
    });
  });
}
