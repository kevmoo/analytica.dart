import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('tool/replay/summarize.dart', () {
    late Directory tempDir;
    late String scriptPath;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('summarize_test_');
      var dir = Directory.current;
      while (!File(
        p.join(dir.path, 'tool', 'replay', 'summarize.dart'),
      ).existsSync()) {
        final parent = dir.parent;
        if (parent.path == dir.path) break;
        dir = parent;
      }
      scriptPath = p.join(dir.path, 'tool', 'replay', 'summarize.dart');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('exits 64 when no paths or --dir are provided', () async {
      final res = await Process.run(Platform.resolvedExecutable, [scriptPath]);
      expect(res.exitCode, 64);
      expect(res.stderr as String, contains('Specify --dir <dir>'));
    });

    test('exits 66 when no run_report.json files exist in directory', () async {
      final res = await Process.run(Platform.resolvedExecutable, [
        scriptPath,
        '--dir',
        tempDir.path,
      ]);
      expect(res.exitCode, 66);
      expect(res.stderr as String, contains('No run_report.json files found'));
    });

    test(
      'renders target metrics and problem tables from run_report.json',
      () async {
        final run1Dir = Directory(p.join(tempDir.path, 'target_a'))
          ..createSync();
        File(p.join(run1Dir.path, 'run_report.json')).writeAsStringSync(
          jsonEncode({
            'schema_version': 1,
            'target': 'qr.dart',
            'track': 'problem',
            'model_tier': 'flash',
            'outcome': 'win',
            'stop_rule_respected': true,
            'collateral_edits': 0,
            'metrics': {
              'new_decls': 1,
              'median_loc_before': 14,
              'median_loc_after': 12,
              'cc_hist_before': {'1': 2, '2': 3, '4': 5},
              'cc_hist_after': {'1': 2, '2': 4, '3': 1, '4': 5},
            },
            'problems': [
              {
                'attribution': 'skill',
                'severity': 'minor',
                'summary': 'Initial callback trampoline',
              },
            ],
          }),
        );

        final outFile = File(p.join(tempDir.path, 'summary.md'));
        final res = await Process.run(Platform.resolvedExecutable, [
          scriptPath,
          '--dir',
          tempDir.path,
          '--out',
          outFile.path,
        ]);

        expect(res.exitCode, 0, reason: '${res.stderr}');
        final stdoutText = res.stdout as String;
        expect(outFile.existsSync(), isTrue);
        expect(outFile.readAsStringSync(), stdoutText);
        expect(
          stdoutText,
          contains(
            '| `qr.dart` | `problem` | `flash` | `win` | yes | 0 | 1 | '
            '`14 -> 12` | `5 -> 7` |',
          ),
        );
        expect(
          stdoutText,
          contains(
            '| `qr.dart` | `flash` | `skill` | `minor` | '
            'Initial callback trampoline |',
          ),
        );
      },
    );
  });
}
