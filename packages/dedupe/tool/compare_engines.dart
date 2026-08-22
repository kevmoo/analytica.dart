import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

class LineSpan {
  final String path;
  final int line;

  const LineSpan(this.path, this.line);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LineSpan && path == other.path && line == other.line;

  @override
  int get hashCode => Object.hash(path, line);

  @override
  String toString() => '$path:$line';
}

class Occurrence {
  final String path;
  final int startLine;
  final int endLine;

  const Occurrence({
    required this.path,
    required this.startLine,
    required this.endLine,
  });

  Set<LineSpan> toLineSpans() {
    final set = <LineSpan>{};
    for (var l = startLine; l <= endLine; l++) {
      set.add(LineSpan(path, l));
    }
    return set;
  }
}

class ToolResult {
  final int totalLines;
  final int duplicateLines;
  final double duplicationPercentage;
  final int clusterCount;
  final Duration elapsed;
  final Set<LineSpan> duplicateLineSpans;

  const ToolResult({
    required this.totalLines,
    required this.duplicateLines,
    required this.duplicationPercentage,
    required this.clusterCount,
    required this.elapsed,
    required this.duplicateLineSpans,
  });
}

class ComparisonReport {
  final String targetPath;
  final ToolResult deslopResult;
  final ToolResult dedupeResult;

  const ComparisonReport({
    required this.targetPath,
    required this.deslopResult,
    required this.dedupeResult,
  });

  int get intersectionCount => deslopResult.duplicateLineSpans
      .intersection(dedupeResult.duplicateLineSpans)
      .length;

  int get unionCount => deslopResult.duplicateLineSpans
      .union(dedupeResult.duplicateLineSpans)
      .length;

  double get jaccardOverlap =>
      unionCount > 0 ? (intersectionCount / unionCount) * 100 : 100.0;

  int get uniqueToDeslopCount => deslopResult.duplicateLineSpans
      .difference(dedupeResult.duplicateLineSpans)
      .length;

  int get uniqueToDedupeCount => dedupeResult.duplicateLineSpans
      .difference(deslopResult.duplicateLineSpans)
      .length;
}

Future<ToolResult> runDeslop({
  required String deslopBin,
  required String targetDir,
  required int minNodes,
  required int minLines,
}) async {
  final tempDir = Directory.systemTemp.createTempSync('deslop_bench_');
  final reportPrefix = p.join(tempDir.path, 'report');

  final sw = Stopwatch()..start();
  final result = await Process.run(deslopBin, [
    targetDir,
    '--min-nodes',
    minNodes.toString(),
    '--output',
    reportPrefix,
    '--nohtml',
    '--notext',
    '--no-color',
  ]);
  sw.stop();

  if (result.exitCode != 0 && result.exitCode != 3) {
    throw ProcessException(
      deslopBin,
      [targetDir],
      'deslop failed (exit ${result.exitCode}):\n'
      '${result.stderr}\n${result.stdout}',
      result.exitCode,
    );
  }

  final jsonFile = File('$reportPrefix.json');
  if (!jsonFile.existsSync()) {
    throw StateError('Deslop report JSON not found at ${jsonFile.path}');
  }

  final data = jsonDecode(jsonFile.readAsStringSync()) as Map<String, dynamic>;
  final metrics = (data['metrics'] as Map<String, dynamic>?) ?? {};
  final totalLoc = (metrics['analysed_loc'] as num?)?.toInt() ?? 0;
  final dupPct = (metrics['duplication_percent'] as num?)?.toDouble() ?? 0.0;

  final clusters = (data['clusters'] as List<dynamic>?) ?? [];
  final occurrences = <Occurrence>[];
  final lineSpans = <LineSpan>{};

  for (final c in clusters) {
    final cMap = c as Map<String, dynamic>;
    final occList = (cMap['occurrences'] as List<dynamic>?) ?? [];
    for (final occ in occList) {
      final oMap = occ as Map<String, dynamic>;
      final path = p.normalize(oMap['path'] as String);
      final sLine = (oMap['start_line'] as num).toInt();
      final eLine = (oMap['end_line'] as num).toInt();
      if ((eLine - sLine + 1) >= minLines) {
        final occurrence = Occurrence(
          path: path,
          startLine: sLine,
          endLine: eLine,
        );
        occurrences.add(occurrence);
        lineSpans.addAll(occurrence.toLineSpans());
      }
    }
  }

  try {
    tempDir.deleteSync(recursive: true);
  } catch (_) {}

  final effectivePct = totalLoc > 0
      ? (lineSpans.length / totalLoc) * 100
      : dupPct;

  return ToolResult(
    totalLines: totalLoc,
    duplicateLines: lineSpans.length,
    duplicationPercentage: effectivePct,
    clusterCount: clusters.length,
    elapsed: sw.elapsed,
    duplicateLineSpans: lineSpans,
  );
}

Future<ToolResult> runDedupe({
  required String targetDir,
  required int minTokens,
  required int minLines,
}) async {
  final tempDir = Directory.systemTemp.createTempSync('dedupe_bench_');
  final jsonPath = p.join(tempDir.path, 'report.json');

  final sw = Stopwatch()..start();
  final result = await Process.run(
    Platform.executable,
    [
      'run',
      'packages/dedupe/bin/dedupe.dart',
      targetDir,
      '--min-tokens',
      minTokens.toString(),
      '--min-lines',
      minLines.toString(),
      '--format=json',
      '--json-output=$jsonPath',
    ],
    workingDirectory:
        '/usr/local/google/home/kevmoo/github/kevmoo/analytica.dart',
  );
  sw.stop();

  if (result.exitCode != 0) {
    throw ProcessException(
      'dedupe',
      [targetDir],
      'dedupe failed (exit ${result.exitCode}):\n'
          '${result.stderr}\n${result.stdout}',
      result.exitCode,
    );
  }

  final jsonFile = File(jsonPath);
  final data = jsonDecode(jsonFile.readAsStringSync()) as Map<String, dynamic>;
  final summary = (data['summary'] as Map<String, dynamic>?) ?? {};
  final totalLoc = (summary['totalLines'] as num?)?.toInt() ?? 0;
  final dupPct = (summary['duplicationPercentage'] as num?)?.toDouble() ?? 0.0;
  final clusterCount = (summary['clusterCount'] as num?)?.toInt() ?? 0;

  final clusters = (data['clusters'] as List<dynamic>?) ?? [];
  final occurrences = <Occurrence>[];
  final lineSpans = <LineSpan>{};

  for (final c in clusters) {
    final cMap = c as Map<String, dynamic>;
    final instList = (cMap['instances'] as List<dynamic>?) ?? [];
    for (final inst in instList) {
      final iMap = inst as Map<String, dynamic>;
      final path = p.normalize(iMap['filePath'] as String);
      final sLine = (iMap['startLine'] as num).toInt();
      final eLine = (iMap['endLine'] as num).toInt();
      final occurrence = Occurrence(
        path: path,
        startLine: sLine,
        endLine: eLine,
      );
      occurrences.add(occurrence);
      lineSpans.addAll(occurrence.toLineSpans());
    }
  }

  try {
    tempDir.deleteSync(recursive: true);
  } catch (_) {}

  final effectivePct = totalLoc > 0
      ? (lineSpans.length / totalLoc) * 100
      : dupPct;

  return ToolResult(
    totalLines: totalLoc,
    duplicateLines: lineSpans.length,
    duplicationPercentage: effectivePct,
    clusterCount: clusterCount,
    elapsed: sw.elapsed,
    duplicateLineSpans: lineSpans,
  );
}

void main(List<String> args) async {
  final parser = ArgParser()
    ..addOption(
      'deslop-bin',
      defaultsTo:
          '/usr/local/google/home/kevmoo/github/Deslop/target/release/deslop',
      help: 'Path to deslop executable binary.',
    )
    ..addOption(
      'min-nodes',
      defaultsTo: '30',
      help: 'Min AST nodes for deslop.',
    )
    ..addOption('min-tokens', defaultsTo: '40', help: 'Min tokens for dedupe.')
    ..addOption('min-lines', defaultsTo: '4', help: 'Min lines.')
    ..addOption(
      'targets',
      help: 'Comma-separated target directories to benchmark.',
    )
    ..addFlag('json', defaultsTo: false, help: 'Output JSON report.')
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show help.');

  final results = parser.parse(args);
  if (results.flag('help')) {
    print('Dedupe vs Deslop A/B Benchmark Harness');
    print(parser.usage);
    return;
  }

  final deslopBin = results.option('deslop-bin')!;
  final minNodes = int.parse(results.option('min-nodes')!);
  final minTokens = int.parse(results.option('min-tokens')!);
  final minLines = int.parse(results.option('min-lines')!);

  final targetList = <String>[];
  if (results.option('targets') != null &&
      results.option('targets')!.isNotEmpty) {
    targetList.addAll(
      results.option('targets')!.split(',').map((s) => s.trim()),
    );
  }
  if (results.rest.isNotEmpty) {
    targetList.addAll(results.rest);
  }

  if (targetList.isEmpty) {
    targetList.addAll([
      '/usr/local/google/home/kevmoo/github/shelf',
      '/usr/local/google/home/kevmoo/github/http',
      '/usr/local/google/home/kevmoo/github/kevmoo/build_cli',
      '/usr/local/google/home/kevmoo/github/built_value.dart',
      '/usr/local/google/home/kevmoo/github/json_serializable.dart',
      '/usr/local/google/home/kevmoo/github/pana',
      '/usr/local/google/home/kevmoo/github/google-cloud-dart',
      '/usr/local/google/home/kevmoo/github/kevmoo/analytica.dart/packages/dedupe',
    ]);
  }

  final reports = <ComparisonReport>[];

  stderr.writeln('=== Starting Dedupe vs Deslop A/B Comparison Sweep ===\n');

  for (final target in targetList) {
    final dir = Directory(target);
    if (!dir.existsSync()) {
      stderr.writeln('⚠️ Skipping non-existent path: $target');
      continue;
    }

    final repoName = p.basename(target);
    stderr.writeln('🔬 Benchmarking: $repoName ($target)...');

    try {
      final deslopResult = await runDeslop(
        deslopBin: deslopBin,
        targetDir: dir.path,
        minNodes: minNodes,
        minLines: minLines,
      );

      final dedupeResult = await runDedupe(
        targetDir: dir.path,
        minTokens: minTokens,
        minLines: minLines,
      );

      final comp = ComparisonReport(
        targetPath: target,
        deslopResult: deslopResult,
        dedupeResult: dedupeResult,
      );
      reports.add(comp);

      final jaccardStr = comp.jaccardOverlap.toStringAsFixed(1);
      final tDeslop = deslopResult.elapsed.inMilliseconds;
      final tDedupe = dedupeResult.elapsed.inMilliseconds;
      stderr.writeln(
        '  ✔ Done! Jaccard Overlap: $jaccardStr% '
        '(Deslop: ${tDeslop}ms | Dedupe: ${tDedupe}ms)\n',
      );
    } catch (e, st) {
      stderr.writeln('  ❌ Error benchmarking $target: $e\n$st\n');
    }
  }

  _printMarkdownReport(reports);
}

void _printMarkdownReport(List<ComparisonReport> reports) {
  print('# 📊 Empirical A/B Benchmark: `pkg:dedupe` vs `deslop`\n');
  print('<!-- mdformat off(prevent table wrapping) -->');
  print(
    '| Repository | Total LOC | Deslop Dup Lines | Dedupe Dup Lines | '
    'Jaccard Overlap | Deslop Time | Dedupe Time | Ratio (Dedupe/Deslop) |',
  );
  print('| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: |');

  for (final r in reports) {
    final name = p.basename(r.targetPath);
    final totalLoc = math.max(
      r.deslopResult.totalLines,
      r.dedupeResult.totalLines,
    );
    final dDup = r.deslopResult.duplicateLines;
    final dPct = r.deslopResult.duplicationPercentage.toStringAsFixed(1);
    final uDup = r.dedupeResult.duplicateLines;
    final uPct = r.dedupeResult.duplicationPercentage.toStringAsFixed(1);
    final overlap = '${r.jaccardOverlap.toStringAsFixed(1)}%';
    final tDeslop = '${r.deslopResult.elapsed.inMilliseconds}ms';
    final tDedupe = '${r.dedupeResult.elapsed.inMilliseconds}ms';
    final ratioNum =
        r.dedupeResult.elapsed.inMilliseconds /
        math.max(1, r.deslopResult.elapsed.inMilliseconds);
    final ratio = ratioNum.toStringAsFixed(2);

    print(
      '| `$name` | $totalLoc | $dDup ($dPct%) | $uDup ($uPct%) | '
      '**$overlap** | $tDeslop | $tDedupe | ${ratio}x |',
    );
  }
  print('<!-- mdformat on -->\n');

  print('## 🔍 Discrepancy & Concordance Breakdown\n');
  print('<!-- mdformat off(prevent table wrapping) -->');
  print(
    '| Repository | In Both (Agreed) | Unique to Deslop | '
    'Unique to Dedupe | Deslop Clusters | Dedupe Clusters |',
  );
  print('| :--- | :---: | :---: | :---: | :---: | :---: |');

  for (final r in reports) {
    final name = p.basename(r.targetPath);
    final agreed = '${r.intersectionCount} lines';
    final uDeslop = '${r.uniqueToDeslopCount} lines';
    final uDedupe = '${r.uniqueToDedupeCount} lines';
    final cDeslop = r.deslopResult.clusterCount;
    final cDedupe = r.dedupeResult.clusterCount;
    print(
      '| `$name` | $agreed | $uDeslop | $uDedupe | '
      '$cDeslop | $cDedupe |',
    );
  }
  print('<!-- mdformat on -->\n');
}
