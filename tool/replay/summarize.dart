import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

/// Rolls up `run_report.json` files produced by replay/hardening runs into
/// Markdown summary tables (by target, Track N metrics, and problem
/// attribution x severity x model tier).
void main(List<String> args) {
  final parser = ArgParser()
    ..addOption(
      'dir',
      abbr: 'd',
      help: 'Directory to scan recursively for run_report.json files.',
    )
    ..addOption(
      'out',
      abbr: 'o',
      help: 'Optional output Markdown file path (also prints to stdout).',
    )
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Print usage information.',
    );

  final parsed = parser.parse(args);
  if (parsed['help'] as bool) {
    stdout.writeln(
      'Usage: dart run tool/replay/summarize.dart [--dir <dir>] [<file_or_dir>...]',
    );
    stdout.writeln(parser.usage);
    return;
  }

  final searchRoots = <String>[
    if (parsed['dir'] case final String dir) dir,
    ...parsed.rest,
  ];
  if (searchRoots.isEmpty) {
    stderr.writeln('Error: Specify --dir <dir> or one or more paths.');
    exitCode = 64;
    return;
  }

  final reportFiles = _collectReportFiles(searchRoots);
  if (reportFiles.isEmpty) {
    stderr.writeln(
      'No run_report.json files found in: ${searchRoots.join(', ')}',
    );
    exitCode = 66;
    return;
  }

  final reports = [for (final file in reportFiles) _parseReport(file)];

  final markdown = _renderSummaryMarkdown(reports);
  stdout.write(markdown);

  if (parsed['out'] case final String outPath) {
    final outFile = File(outPath);
    outFile.parent.createSync(recursive: true);
    outFile.writeAsStringSync(markdown);
  }
}

List<File> _collectReportFiles(List<String> roots) {
  final files = <File>[];
  for (final root in roots) {
    final type = FileSystemEntity.typeSync(root);
    if (type == FileSystemEntityType.file) {
      files.add(File(root));
    } else if (type == FileSystemEntityType.directory) {
      final entries = Directory(root)
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => p.basename(f.path) == 'run_report.json');
      files.addAll(entries);
    }
  }
  files.sort((a, b) => a.path.compareTo(b.path));
  return files;
}

Map<String, dynamic> _parseReport(File file) {
  final decoded = jsonDecode(file.readAsStringSync());
  if (decoded is! Map<String, dynamic>) {
    throw FormatException('Expected JSON object in ${file.path}');
  }
  return decoded;
}

String _renderSummaryMarkdown(List<Map<String, dynamic>> reports) {
  final buf = StringBuffer()
    ..writeln('# Cognitive Complexity Replay Summary')
    ..writeln()
    ..writeln('## Runs by Target')
    ..writeln()
    ..writeln(
      '| Target | Track | Tier | Outcome | Stop Rule | Collateral | '
      'New Decls | Median LOC (`Before -> After`) | '
      'helpers CC 1–3 (`Before -> After`) |',
    )
    ..writeln(
      '| :--- | :--- | :--- | :--- | :--- | ---: | ---: | :---: | :---: |',
    );

  for (final r in reports) {
    buf.writeln(_formatTargetRow(r));
  }

  buf
    ..writeln()
    ..writeln('## Problems by Attribution × Severity × Model Tier')
    ..writeln();
  _writeProblemsTable(reports, buf);
  return buf.toString();
}

String _formatTargetRow(Map<String, dynamic> r) {
  final target = r['target'] ?? 'unknown';
  final track = r['track'] ?? 'unknown';
  final tier = r['model_tier'] ?? 'unknown';
  final outcome = r['outcome'] ?? 'unknown';
  final stopRule = r['stop_rule_respected'] == true ? 'yes' : 'no';
  final collateral = r['collateral_edits'] ?? 0;
  final metrics = (r['metrics'] as Map<String, dynamic>?) ?? const {};
  final newDecls = metrics['new_decls'] ?? 0;
  final locBefore = metrics['median_loc_before'] ?? 0;
  final locAfter = metrics['median_loc_after'] ?? 0;
  final lowBefore = _countLowCc(metrics['cc_hist_before']);
  final lowAfter = _countLowCc(metrics['cc_hist_after']);
  return '| `$target` | `$track` | `$tier` | `$outcome` | $stopRule | '
      '$collateral | $newDecls | `$locBefore -> $locAfter` | '
      '`$lowBefore -> $lowAfter` |';
}

int _countLowCc(Object? rawHist) {
  if (rawHist is! Map) return 0;
  var total = 0;
  for (final key in const ['1', '2', '3']) {
    final val = rawHist[key];
    if (val is int) total += val;
  }
  return total;
}

void _writeProblemsTable(List<Map<String, dynamic>> reports, StringBuffer buf) {
  final rows = <String>[];
  for (final r in reports) {
    final target = r['target'] ?? 'unknown';
    final tier = r['model_tier'] ?? 'unknown';
    final problems = (r['problems'] as List?) ?? const [];
    for (final raw in problems) {
      if (raw is! Map) continue;
      final attr = raw['attribution'] ?? 'unknown';
      final sev = raw['severity'] ?? 'unknown';
      final summary = (raw['summary'] ?? '').toString().replaceAll('\n', ' ');
      rows.add('| `$target` | `$tier` | `$attr` | `$sev` | $summary |');
    }
  }

  if (rows.isEmpty) {
    buf.writeln('No problems reported across ${reports.length} run(s).');
    return;
  }

  buf
    ..writeln('| Target | Tier | Attribution | Severity | Summary |')
    ..writeln('| :--- | :--- | :--- | :--- | :--- |');
  for (final row in rows) {
    buf.writeln(row);
  }
}
