@TestOn('!windows')
library;

import 'dart:io';

import 'package:analytica/testing.dart';
import 'package:checks/checks.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

/// Extracts the `run: |` bash script of the composite step named [stepName]
/// from [actionYml].
String _extractStepScript(String actionYml, String stepName) {
  final lines = actionYml.split('\n');
  final header = '- name: $stepName';
  final stepIndex = lines.indexWhere((l) => l.trim() == header);
  if (stepIndex < 0) {
    throw StateError('Step "$stepName" not found in action.yml');
  }
  final runIndex = lines.indexWhere((l) => l.trim() == 'run: |', stepIndex + 1);
  if (runIndex < 0) {
    throw StateError('No `run: |` block for step "$stepName"');
  }

  final scriptLines = <String>[];
  int? baseIndent;
  for (var i = runIndex + 1; i < lines.length; i++) {
    final line = lines[i];
    if (line.trim().isEmpty) {
      scriptLines.add('');
      continue;
    }
    final indent = line.length - line.trimLeft().length;
    baseIndent ??= indent;
    if (indent < baseIndent) break;
    scriptLines.add(line.substring(baseIndent));
  }
  return scriptLines.join('\n');
}

void main() {
  late String prepareScript;
  late String executeScript;

  setUpAll(() async {
    final actionFile = await resolvePackageFile(
      'package:cognitive_complexity/cognitive_complexity.dart',
      'action.yml',
    );
    final actionYml = await actionFile.readAsString();
    prepareScript = _extractStepScript(
      actionYml,
      'Resolve Diff Base & Fetch History',
    );
    executeScript = _extractStepScript(
      actionYml,
      'Execute Cognitive Complexity Scanner',
    );
  });

  group('action.yml prepare step (scan-mode)', () {
    Future<
      ({
        int exitCode,
        String stdout,
        String stderr,
        String githubOutput,
        String gitLog,
      })
    >
    runPrepare(Map<String, String> env) async {
      final stubBin = p.join(d.sandbox, 'prepare_bin');
      final gitLogPath = p.join(d.sandbox, 'git.log');
      final githubOutputPath = p.join(d.sandbox, 'github_output.txt');
      await Directory(stubBin).create(recursive: true);
      await File(gitLogPath).writeAsString('');
      await File(githubOutputPath).writeAsString('');

      final gitStub = File(p.join(stubBin, 'git'));
      await gitStub.writeAsString(
        '#!/usr/bin/env bash\necho "\$@" >> "$gitLogPath"\n',
      );
      await Process.run('chmod', ['+x', gitStub.path]);

      final res = await Process.run(
        'bash',
        ['-euo', 'pipefail', '-c', prepareScript],
        environment: {
          'PATH': '$stubBin:${Platform.environment['PATH']}',
          'GITHUB_OUTPUT': githubOutputPath,
          'INPUT_SCAN_MODE': 'diff',
          'INPUT_DIFF_BASE': '',
          'EVENT_NAME': 'pull_request',
          'BASE_REF': 'main',
          ...env,
        },
      );
      return (
        exitCode: res.exitCode,
        stdout: res.stdout as String,
        stderr: res.stderr as String,
        githubOutput: await File(githubOutputPath).readAsString(),
        gitLog: await File(gitLogPath).readAsString(),
      );
    }

    test('scan-mode=diff resolves PR base and fetches history', () async {
      final res = await runPrepare({'INPUT_SCAN_MODE': 'diff'});
      check(res.exitCode).equals(0);
      check(res.githubOutput.trim()).equals('diff_arg=--git-diff=origin/main');
      check(res.gitLog).contains('fetch origin main');
    });

    test('scan-mode=full skips diff resolution and git fetch on PRs', () async {
      final res = await runPrepare({'INPUT_SCAN_MODE': 'full'});
      check(res.exitCode).equals(0);
      check(res.githubOutput.trim()).equals('diff_arg=');
      check(res.gitLog.trim()).isEmpty;
    });

    test('scan-mode=full warns and ignores explicit diff-base', () async {
      final res = await runPrepare({
        'INPUT_SCAN_MODE': 'full',
        'INPUT_DIFF_BASE': 'origin/develop',
      });
      check(res.exitCode).equals(0);
      check(res.githubOutput.trim()).equals('diff_arg=');
      check(res.stdout).contains(
        "::warning::diff-base ('origin/develop') is ignored when scan-mode is 'full'.",
      );
      check(res.gitLog.trim()).isEmpty;
    });

    test('rejects invalid scan-mode with exit code 1', () async {
      final res = await runPrepare({'INPUT_SCAN_MODE': 'bogus'});
      check(res.exitCode).equals(1);
      check(
        res.stdout,
      ).contains("::error::scan-mode must be 'diff' or 'full', got 'bogus'.");
    });
  });

  group('action.yml execute step (comment-mode)', () {
    Future<
      ({
        int exitCode,
        String stdout,
        String dartLog,
        String ghLog,
        String patchedBody,
      })
    >
    runExecute({
      Map<String, String> env = const {},
      int scannerExitCode = 0,
      String? commentContent,
      String existingCommentId = '',
    }) async {
      final workDir = p.join(d.sandbox, 'exec_work');
      final actionDir = p.join(d.sandbox, 'exec_action');
      final runnerTemp = p.join(d.sandbox, 'exec_temp');
      final stubBin = p.join(d.sandbox, 'exec_bin');
      final dartLogPath = p.join(d.sandbox, 'dart.log');
      final ghLogPath = p.join(d.sandbox, 'gh.log');
      final patchedBodyPath = p.join(d.sandbox, 'patched.md');

      for (final dir in [workDir, actionDir, runnerTemp, stubBin]) {
        await Directory(dir).create(recursive: true);
      }
      await File(dartLogPath).writeAsString('');
      await File(ghLogPath).writeAsString('');
      await File(patchedBodyPath).writeAsString('');

      final writeCommentSnippet = commentContent == null
          ? ''
          : '''
for arg in "\$@"; do
  case "\$arg" in
    --comment-output=*)
      printf '%s' ${ShellQuote.single(commentContent)} > "\${arg#--comment-output=}"
      ;;
  esac
done
''';
      final dartStub = File(p.join(stubBin, 'dart'));
      await dartStub.writeAsString('''#!/usr/bin/env bash
if [ "\$1" = "pub" ]; then
  exit 0
fi
printf '[%s]\\n' "\$@" >> "$dartLogPath"
$writeCommentSnippet
exit $scannerExitCode
''');
      await Process.run('chmod', ['+x', dartStub.path]);

      final ghStub = File(p.join(stubBin, 'gh'));
      await ghStub.writeAsString('''#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "$ghLogPath"
if [ "\$1" = "api" ] && [ "\$2" = "--paginate" ]; then
  if [ -n "$existingCommentId" ]; then
    echo "$existingCommentId"
  fi
  exit 0
fi
for arg in "\$@"; do
  case "\$arg" in
    body=@*)
      cp "\${arg#body=@}" "$patchedBodyPath"
      ;;
  esac
done
exit 0
''');
      await Process.run('chmod', ['+x', ghStub.path]);

      final res = await Process.run(
        'bash',
        ['-euo', 'pipefail', '-c', executeScript],
        environment: {
          'PATH': '$stubBin:${Platform.environment['PATH']}',
          'RUNNER_TEMP': runnerTemp,
          'GITHUB_WORKSPACE': workDir,
          'GITHUB_REPOSITORY': 'owner/repo',
          'GITHUB_RUN_ID': '42',
          'ACTION_PATH': actionDir,
          'GH_TOKEN': 'tok',
          'PR_NUMBER': '7',
          'HEAD_SHA': 'abcdef1234567',
          'DIFF_ARG': '--git-diff=origin/main',
          'INPUT_SCAN_MODE': 'diff',
          'INPUT_THRESHOLD': '0',
          'INPUT_FAIL_THRESHOLD': '15',
          'INPUT_MAX_FILE_LINES': '',
          'INPUT_MAX_FUNCTION_LINES': '',
          'INPUT_COVERAGE': '',
          'INPUT_FAIL_ON_INCREASE': 'false',
          'INPUT_FORMAT': 'github',
          'INPUT_TARGETS': '',
          'INPUT_COMMENT_MODE': 'auto',
          'INPUT_MAX_COMMENT_ROWS': '0',
          ...env,
        },
      );
      return (
        exitCode: res.exitCode,
        stdout: res.stdout as String,
        dartLog: await File(dartLogPath).readAsString(),
        ghLog: await File(ghLogPath).readAsString(),
        patchedBody: await File(patchedBodyPath).readAsString(),
      );
    }

    test('comment-mode=off skips --comment-output and all gh calls', () async {
      final res = await runExecute(
        env: {'INPUT_COMMENT_MODE': 'off'},
        scannerExitCode: 1,
        commentContent: 'should not be written',
      );
      check(res.exitCode).equals(1);
      check(res.dartLog).not(.it()..contains('--comment-output'));
      check(res.ghLog.trim()).isEmpty;
    });

    test(
      'comment-mode=auto posts on sub-threshold increase (exit 0)',
      () async {
        final res = await runExecute(
          env: {'INPUT_COMMENT_MODE': 'auto'},
          scannerExitCode: 0,
          commentContent: '<!-- complexity-comment-marker -->\nreport\n',
        );
        check(res.exitCode).equals(0);
        check(res.dartLog)
          ..contains('--comment-output=')
          ..not(.it()..contains('--comment-on-clean'));
        check(res.ghLog).contains('pr comment 7');
      },
    );

    test('comment-mode=on-violation stays silent on sub-threshold increase '
        'when no prior comment exists', () async {
      final res = await runExecute(
        env: {'INPUT_COMMENT_MODE': 'on-violation'},
        scannerExitCode: 0,
        commentContent: '<!-- complexity-comment-marker -->\nreport\n',
      );
      check(res.exitCode).equals(0);
      check(res.ghLog)
        ..not(.it()..contains('pr comment'))
        ..not(.it()..contains('PATCH'));
    });

    test(
      'comment-mode=on-violation resolves stale sticky comment on exit 0',
      () async {
        final res = await runExecute(
          env: {'INPUT_COMMENT_MODE': 'on-violation'},
          scannerExitCode: 0,
          commentContent: '<!-- complexity-comment-marker -->\nsub-threshold\n',
          existingCommentId: '999',
        );
        check(res.exitCode).equals(0);
        check(res.ghLog).contains('PATCH repos/owner/repo/issues/comments/999');
        check(
          res.patchedBody,
        ).contains('Clean - no complexity violations in the current diff.');
      },
    );

    test(
      'comment-mode=on-violation posts comment on violation (exit 1)',
      () async {
        final res = await runExecute(
          env: {'INPUT_COMMENT_MODE': 'on-violation'},
          scannerExitCode: 1,
          commentContent: '<!-- complexity-comment-marker -->\nviolation\n',
        );
        check(res.exitCode).equals(1);
        check(res.ghLog).contains('pr comment 7');
      },
    );

    test(
      'comment-mode=always passes --comment-on-clean and posts on exit 0',
      () async {
        final res = await runExecute(
          env: {'INPUT_COMMENT_MODE': 'always'},
          scannerExitCode: 0,
          commentContent: '<!-- complexity-comment-marker -->\nclean summary\n',
        );
        check(res.exitCode).equals(0);
        check(res.dartLog)
          ..contains('--comment-output=')
          ..contains('--comment-on-clean');
        check(res.ghLog).contains('pr comment 7');
      },
    );

    test(
      'scan-mode=full passes no --git-diff and uses scan resolved copy',
      () async {
        final res = await runExecute(
          env: {
            'INPUT_SCAN_MODE': 'full',
            'DIFF_ARG': '',
            'INPUT_COMMENT_MODE': 'auto',
          },
          scannerExitCode: 0,
          existingCommentId: '321',
        );
        check(res.exitCode).equals(0);
        check(res.dartLog)
          ..not(.it()..contains('--git-diff'))
          ..contains('--comment-output=');
        check(res.ghLog).contains('PATCH repos/owner/repo/issues/comments/321');
        check(
          res.patchedBody,
        ).contains('Clean - no complexity violations in the current scan.');
      },
    );

    test('crash (non-zero exit with no comment file) never resolves stale '
        'sticky comment', () async {
      final res = await runExecute(
        env: {'INPUT_COMMENT_MODE': 'auto'},
        scannerExitCode: 2,
        existingCommentId: '555',
      );
      check(res.exitCode).equals(2);
      check(res.ghLog).not(.it()..contains('PATCH'));
    });

    test('rejects invalid comment-mode with exit code 1', () async {
      final res = await runExecute(env: {'INPUT_COMMENT_MODE': 'invalid'});
      check(res.exitCode).equals(1);
      check(res.stdout).contains(
        "::error::comment-mode must be one of 'auto', 'on-violation', "
        "'always', or 'off', got 'invalid'.",
      );
    });

    test('updates existing sticky comment via PATCH when posting', () async {
      final res = await runExecute(
        env: {'INPUT_COMMENT_MODE': 'always'},
        scannerExitCode: 0,
        commentContent: '<!-- complexity-comment-marker -->\nupdated report\n',
        existingCommentId: '777',
      );
      check(res.exitCode).equals(0);
      check(res.ghLog)
        ..contains('PATCH repos/owner/repo/issues/comments/777')
        ..not(.it()..contains('pr comment'));
      check(res.patchedBody).contains('updated report');
    });

    test(
      'comment-mode=auto resolves stale sticky comment with diff copy',
      () async {
        final res = await runExecute(
          env: {'INPUT_COMMENT_MODE': 'auto'},
          scannerExitCode: 0,
          existingCommentId: '888',
        );
        check(res.exitCode).equals(0);
        check(res.ghLog).contains('PATCH repos/owner/repo/issues/comments/888');
        check(
          res.patchedBody,
        ).contains('Clean - no complexity regressions in the current diff.');
      },
    );

    test('skips --comment-output and gh calls outside PR context', () async {
      final res = await runExecute(
        env: {'PR_NUMBER': '', 'INPUT_COMMENT_MODE': 'always'},
        scannerExitCode: 0,
      );
      check(res.exitCode).equals(0);
      check(res.dartLog).not(.it()..contains('--comment-output'));
      check(res.ghLog.trim()).isEmpty;
    });

    test('scan-mode=full warns and omits --fail-on-increase, and empty '
        'fail-threshold omits --fail-threshold', () async {
      final res = await runExecute(
        env: {
          'INPUT_SCAN_MODE': 'full',
          'DIFF_ARG': '',
          'INPUT_FAIL_ON_INCREASE': 'true',
          'INPUT_FAIL_THRESHOLD': '',
          'INPUT_COMMENT_MODE': 'off',
        },
        scannerExitCode: 0,
      );
      check(res.exitCode).equals(0);
      check(res.stdout).contains(
        "::warning::fail-on-increase is ignored when scan-mode is 'full'.",
      );
      check(res.dartLog)
        ..not(.it()..contains('--fail-on-increase'))
        ..not(.it()..contains('--fail-threshold'))
        ..not(.it()..contains('--coverage='));
    });

    test(
      'forwards --coverage when coverage input is set (including spaces)',
      () async {
        final res = await runExecute(
          env: {
            'INPUT_COVERAGE': 'my coverage/lcov.info',
            'INPUT_COMMENT_MODE': 'off',
          },
          scannerExitCode: 0,
        );
        check(res.exitCode).equals(0);
        check(res.dartLog).contains('[--coverage=my coverage/lcov.info]');
      },
    );
  });
}

abstract final class ShellQuote {
  static String single(String value) => "'${value.replaceAll("'", "'\\''")}'";
}
