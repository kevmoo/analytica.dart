import 'dart:io';
import 'package:checks/checks.dart';
import 'package:cognitive_complexity/src/complexity/delta_analyzer.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

/// A declaration complex enough to be reported at any sensible threshold.
String get _complex {
  final buf = StringBuffer('int stub(int x) {\n');
  for (var i = 0; i < 4; i++) {
    final pad = '  ' * (i + 1);
    buf
      ..writeln('${pad}if (x > $i) {')
      ..writeln('$pad  for (var j = 0; j < x; j++) {')
      ..writeln('$pad    if (j % 2 == 0) x++; else x--;')
      ..writeln('$pad  }');
  }
  for (var i = 3; i >= 0; i--) {
    buf.writeln('${'  ' * (i + 1)}}');
  }
  return (buf
        ..writeln('  return x;')
        ..writeln('}'))
      .toString();
}

void main() {
  group('compileExcludeGlobs', () {
    test('drops blank entries rather than throwing', () {
      // A trailing comma or an unset CI variable produces these, and
      // Glob('') throws.
      check(compileExcludeGlobs(['', '  ', '**.g.dart'])).length.equals(1);
      check(compileExcludeGlobs(const [])).isEmpty();
    });

    test('reports the offending pattern on malformed input', () {
      check(
          () => compileExcludeGlobs(['[unclosed']),
        ).throws<FormatException>().has((e) => e.message, 'message')
        ..contains('[unclosed')
        ..contains('Invalid exclude pattern');
    });
  });

  group('--exclude', () {
    late String repoPath;
    late String binPath;

    Future<void> runGit(List<String> args) async {
      final res = await Process.run('git', args, workingDirectory: repoPath);
      if (res.exitCode != 0) {
        fail('git ${args.join(" ")} failed:\n${res.stderr}');
      }
    }

    /// Basenames of the files the scanner reported deltas for.
    Future<Set<String>> scannedFiles(List<String> extraArgs) async {
      final res = await Process.run(Platform.resolvedExecutable, [
        binPath,
        '--git-diff=HEAD~1',
        '--fail-threshold=15',
        '--format=json',
        ...extraArgs,
        'lib',
      ], workingDirectory: repoPath);
      final out = (res.stdout as String).trim();
      if (out.isEmpty) return {};
      return RegExp(
        r'"file":"([^"]+)"',
      ).allMatches(out).map((m) => p.basename(m.group(1)!)).toSet();
    }

    setUp(() async {
      binPath = File('bin/cognitive_complexity.dart').existsSync()
          ? p.normalize(p.absolute('bin/cognitive_complexity.dart'))
          : p.normalize(
              p.absolute(
                'packages/cognitive_complexity/bin/cognitive_complexity.dart',
              ),
            );
      repoPath = p.join(d.sandbox, 'repo');
      await Directory(p.join(repoPath, 'lib')).create(recursive: true);

      await runGit(['init', '-b', 'main']);
      await runGit(['config', 'user.name', 'Tester']);
      await runGit(['config', 'user.email', 'test@example.com']);
      await runGit(['config', 'commit.gpgsign', 'false']);

      const names = ['handwritten.dart', 'model.g.dart', 'model.freezed.dart'];
      for (final n in names) {
        await File(
          p.join(repoPath, 'lib', n),
        ).writeAsString('int stub() => 0;');
      }
      await runGit(['add', '.']);
      await runGit(['commit', '-m', 'base']);

      for (final n in names) {
        await File(p.join(repoPath, 'lib', n)).writeAsString(_complex);
      }
      await runGit(['add', '.']);
      await runGit(['commit', '-m', 'head']);
    });

    test('scans every changed file when no pattern is given', () async {
      // Default is empty: opting in is required, nothing is skipped silently.
      check(await scannedFiles([])).unorderedEquals({
        'handwritten.dart',
        'model.g.dart',
        'model.freezed.dart',
      });
    });

    test('skips files matching a single pattern', () async {
      check(
        await scannedFiles(['--exclude=**.g.dart']),
      ).unorderedEquals({'handwritten.dart', 'model.freezed.dart'});
    });

    test('accepts a comma-separated list', () async {
      check(
        await scannedFiles(['--exclude=**.g.dart,**.freezed.dart']),
      ).unorderedEquals({'handwritten.dart'});
    });

    test('accepts the flag repeated', () async {
      check(
        await scannedFiles([
          '--exclude=**.g.dart',
          '--exclude=**.freezed.dart',
        ]),
      ).unorderedEquals({'handwritten.dart'});
    });

    test('tolerates a trailing comma', () async {
      // Produces a blank entry, which Glob('') would reject.
      check(
        await scannedFiles(['--exclude=**.g.dart,']),
      ).unorderedEquals({'handwritten.dart', 'model.freezed.dart'});
    });

    test('warns when used without --git-diff', () async {
      final res = await Process.run(Platform.resolvedExecutable, [
        binPath,
        '--exclude=**.g.dart',
        'lib',
      ], workingDirectory: repoPath);
      check(
        res.stderr as String,
      ).contains('--exclude has no effect unless --git-diff');
    });
  });
}
