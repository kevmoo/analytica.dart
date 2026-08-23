import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:lower_bound/src/cli.dart';
import 'package:lower_bound/src/sdk_discovery.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;
import 'package:test_process/test_process.dart';

String _resolveBinPath() {
  var dir = Directory.current;
  while (true) {
    final candidate = File(
      p.join(dir.path, 'packages', 'lower_bound', 'bin', 'lower_bound.dart'),
    );
    if (candidate.existsSync()) return candidate.path;

    final direct = File(p.join(dir.path, 'bin', 'lower_bound.dart'));
    if (direct.existsSync()) return direct.path;

    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return p.join(Directory.current.path, 'bin', 'lower_bound.dart');
}

void main() {
  final binPath = _resolveBinPath();

  group('CLI Options & Resolution', () {
    test('displays help with --help and exits 0', () async {
      final out = StringBuffer();
      final exitCode = await runLowerBoundCli(['--help'], stdoutSink: out);
      check(exitCode).equals(0);
      check(out.toString()).contains(
        'Validate Dart package compilation against dependency lower bounds.',
      );
    });

    test('exits 64 on invalid argument', () async {
      final err = StringBuffer();
      final exitCode = await runLowerBoundCli([
        '--non-existent-flag',
      ], stderrSink: err);
      check(exitCode).equals(64);
      check(err.toString()).contains('Could not find an option');
    });

    test('exits 64 on invalid --sdk argument', () async {
      final err = StringBuffer();
      final exitCode = await runLowerBoundCli([
        '--sdk=invalid-sdk-version',
        '.',
      ], stderrSink: err);
      check(exitCode).equals(64);
      check(err.toString()).contains('Invalid --sdk');
    });

    test('exits 66 when target directory does not exist', () async {
      final err = StringBuffer();
      final exitCode = await runLowerBoundCli([
        '/non/existent/directory/path',
      ], stderrSink: err);
      check(exitCode).equals(66);
      check(err.toString()).contains('Directory does not exist');
    });

    test('exits 66 when directory has no pubspec.yaml', () async {
      await d.dir('empty_dir', []).create();

      final err = StringBuffer();
      final exitCode = await runLowerBoundCli([
        p.join(d.sandbox, 'empty_dir'),
      ], stderrSink: err);
      check(exitCode).equals(66);
      check(err.toString()).contains('No pubspec.yaml found');
    });

    test(
      'writes sticky PR comment with marker and honors max-comment-rows',
      () async {
        await d.dir('valid_pkg', [
          d.file('pubspec.yaml', '''
name: valid_pkg
environment:
  sdk: '^3.12.0'
'''),
          d.dir('lib', [d.file('valid_pkg.dart', 'const a = 1;')]),
        ]).create();

        final commentFile = p.join(d.sandbox, 'nested_dir', 'comment.md');

        final proc = await TestProcess.start(dartExecutable, [
          binPath,
          '--comment-output=$commentFile',
          '--max-comment-rows=1',
          p.join(d.sandbox, 'valid_pkg'),
        ]);
        await proc.shouldExit(0);

        final commentContent = File(commentFile).readAsStringSync();
        check(commentContent).contains('<!-- lower-bound-comment-marker -->');
        check(
          commentContent,
        ).contains('## 📦 Dependency Lower-Bound Validation Summary');
        check(commentContent).contains('valid_pkg');
      },
    );

    test('formats output as JSON with --format=json', () async {
      await d.dir('json_pkg', [
        d.file('pubspec.yaml', '''
name: json_pkg
environment:
  sdk: '^3.12.0'
'''),
        d.dir('lib', [d.file('json_pkg.dart', 'const a = 1;')]),
      ]).create();

      final proc = await TestProcess.start(dartExecutable, [
        binPath,
        '--format=json',
        p.join(d.sandbox, 'json_pkg'),
      ]);

      final output = await proc.stdout.rest.toList();
      await proc.shouldExit(0);

      final jsonStr = output.join('\n');
      final decoded = jsonDecode(jsonStr) as List;
      check(decoded).length.equals(1);
      final entry = decoded.first as Map<String, dynamic>;
      check(entry['package']).equals('json_pkg');
      check(entry['clean']).equals(true);
    });

    test(
      'expands workspace members when explicit path is workspace root',
      () async {
        await d.dir('explicit_workspace', [
          d.file('pubspec.yaml', '''
name: workspace_root
workspace:
  - member_a
  - member_b
environment:
  sdk: '^3.12.0'
'''),
          d.dir('member_a', [
            d.file('pubspec.yaml', '''
name: member_a
environment:
  sdk: '^3.12.0'
'''),
            d.dir('lib', [d.file('member_a.dart', 'const a = 1;')]),
          ]),
          d.dir('member_b', [
            d.file('pubspec.yaml', '''
name: member_b
environment:
  sdk: '^3.12.0'
'''),
            d.dir('lib', [d.file('member_b.dart', 'const b = 2;')]),
          ]),
        ]).create();

        final out = StringBuffer();
        final exitCode = await runLowerBoundCli([
          p.join(d.sandbox, 'explicit_workspace'),
        ], stdoutSink: out);
        check(exitCode).equals(0);
        check(out.toString()).contains('member_a');
        check(out.toString()).contains('member_b');
      },
    );
  });
}
