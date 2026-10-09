import 'dart:convert';
import 'dart:io';

const repos = [
  'bench_press',
  'build_verify',
  'build_version',
  'completion.dart',
  'dhttpd',
  'flutter_web_cache_check',
  'flutter_web_perf',
  'fuzz.dart',
  'git',
  'lower_bound.dart',
  'md_live',
  'peanut.dart',
  'pubviz',
  'qr.dart',
  'scripts.dart',
  'source_gen_test',
  'stats',
  'whats_new',
];

void main(List<String> args) async {
  String outDir = Directory.current.path;
  if (args.contains('--out')) {
    final idx = args.indexOf('--out');
    if (idx + 1 < args.length) {
      outDir = args[idx + 1];
    }
  }

  final workDir = Directory.systemTemp.createTempSync('canary_');
  print('Working in \${workDir.path}...');

  // Clone
  for (final repo in repos) {
    print('Cloning \$repo...');
    final result = await Process.run('git', [
      'clone',
      '--depth=1',
      'https://github.com/kevmoo/\$repo.git',
      '\${workDir.path}/\$repo',
    ]);
    if (result.exitCode != 0) {
      print('Failed to clone \$repo: \${result.stderr}');
    }
  }

  print('Not fully implemented yet.');
  // To implement:
  // Run tool at last release
  // Run tool at current main
  // Diff JSON
  // Write canary_report.md
}
