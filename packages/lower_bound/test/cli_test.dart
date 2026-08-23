import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:lower_bound/lower_bound.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;
import 'package:test_process/test_process.dart';

void main() {
  final binPath = p.normalize(
    p.join(
      Directory.current.path,
      'packages',
      'lower_bound',
      'bin',
      'lower_bound.dart',
    ),
  );

  group('CLI Options & Resolution', () {
    test('displays help with --help and exits 0', () async {
      final proc = await TestProcess.start(dartExecutable, [binPath, '--help']);
      expect(
        proc.stdout,
        emitsThrough(
          'Validate Dart package compilation against dependency lower bounds.',
        ),
      );
      await proc.shouldExit(0);
    });

    test('exits 64 on invalid argument', () async {
      final proc = await TestProcess.start(dartExecutable, [
        binPath,
        '--non-existent-flag',
      ]);
      expect(proc.stderr, emitsThrough(contains('Could not find an option')));
      await proc.shouldExit(64);
    });

    test('exits 66 when target directory does not exist', () async {
      final proc = await TestProcess.start(dartExecutable, [
        binPath,
        '/non/existent/directory/path',
      ]);
      expect(proc.stderr, emitsThrough(contains('Directory does not exist')));
      await proc.shouldExit(66);
    });

    test('exits 66 when directory has no pubspec.yaml', () async {
      await d.dir('empty_dir', []).create();

      final proc = await TestProcess.start(dartExecutable, [
        binPath,
        p.join(d.sandbox, 'empty_dir'),
      ]);
      expect(proc.stderr, emitsThrough(contains('No pubspec.yaml found')));
      await proc.shouldExit(66);
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

        final commentFile = p.join(d.sandbox, 'comment.md');

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
  });
}
