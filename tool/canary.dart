import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

const consumerRepos = [
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

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption(
      'out',
      abbr: 'o',
      defaultsTo: '.',
      help: 'Directory to write canary_report.md and raw JSON outputs.',
    )
    ..addOption(
      'repos-dir',
      help:
          'Optional parent directory containing local checkouts of consumer '
          'repos (defaults to sibling directory if present, else clones).',
    )
    ..addOption(
      'baseline-ref',
      defaultsTo: 'cognitive_complexity-v1.0.0',
      help: 'Git ref for baseline cognitive_complexity version.',
    )
    ..addMultiOption(
      'extra',
      help: 'Additional label=path target directories to sweep.',
    )
    ..addFlag(
      'skip-consumers',
      negatable: false,
      help: 'Only run --extra targets (skip the 18 consumer repos).',
    )
    ..addFlag('help', abbr: 'h', negatable: false);

  final parsed = parser.parse(args);
  if (parsed['help'] as bool) {
    stdout.writeln('Usage: dart run tool/canary.dart [options]');
    stdout.writeln(parser.usage);
    return;
  }

  final outDir = Directory(parsed['out'] as String)
    ..createSync(recursive: true);
  final baselineRef = parsed['baseline-ref'] as String;
  final repoRoot = await _resolveAnalyticaRoot();
  final workDir = Directory.systemTemp.createTempSync('cogcomp_canary_');

  try {
    final snapshotBundle = await _buildToolSnapshots(
      repoRoot: repoRoot,
      baselineRef: baselineRef,
      workDir: workDir,
    );
    final targets = await _resolveTargets(
      repoRoot: repoRoot,
      reposDirOpt: parsed['repos-dir'] as String?,
      extraSpecs: parsed['extra'] as List<String>,
      skipConsumers: parsed['skip-consumers'] as bool,
      workDir: workDir,
    );

    final results = <_TargetCanaryResult>[];
    for (final target in targets) {
      stdout.writeln('Sweeping ${target.label} (${target.path})...');
      results.add(await _sweepTarget(target, snapshotBundle));
    }

    final reportMd = _renderCanaryReport(
      results: results,
      baselineRef: baselineRef,
    );
    final reportFile = File(p.join(outDir.path, 'canary_report.md'));
    reportFile.writeAsStringSync(reportMd);
    final jsonFile = File(p.join(outDir.path, 'canary_results.json'));
    jsonFile.writeAsStringSync(
      const JsonEncoder.withIndent(
        '  ',
      ).convert([for (final r in results) r.toJson()]),
    );
    stdout.writeln('Wrote ${reportFile.path} and ${jsonFile.path}');
  } finally {
    workDir.deleteSync(recursive: true);
  }
}

Future<String> _resolveAnalyticaRoot() async {
  final res = await Process.run('git', ['rev-parse', '--show-toplevel']);
  if (res.exitCode != 0) {
    throw StateError('Failed to locate git root: ${res.stderr}');
  }
  return (res.stdout as String).trim();
}

typedef _ToolSnapshots = ({
  String v1ComplexityDill,
  String v2ComplexityDill,
  String v1ShallowDill,
  String v2ShallowDill,
  String v1FileSplitDill,
  String v2FileSplitDill,
});

Future<_ToolSnapshots> _buildToolSnapshots({
  required String repoRoot,
  required String baselineRef,
  required Directory workDir,
}) async {
  final v1Dir = Directory(p.join(workDir.path, 'v1'))..createSync();
  final archive = await Process.run('bash', [
    '-c',
    'git archive "$baselineRef" packages/cognitive_complexity | tar -x -C "${v1Dir.path}"',
  ], workingDirectory: repoRoot);
  if (archive.exitCode != 0) {
    throw StateError('git archive $baselineRef failed: ${archive.stderr}');
  }

  final v2PkgConfig = p.join(repoRoot, '.dart_tool', 'package_config.json');
  final v1PkgConfig = _writeBaselinePackageConfig(
    v2PkgConfigPath: v2PkgConfig,
    v1PkgDir: p.join(v1Dir.path, 'packages', 'cognitive_complexity'),
    outPath: p.join(workDir.path, 'v1_package_config.json'),
  );

  final v1Bin = p.join(v1Dir.path, 'packages', 'cognitive_complexity', 'bin');
  final v2Bin = p.join(repoRoot, 'packages', 'cognitive_complexity', 'bin');

  Future<String> compile(String pkgCfg, String script, String name) async {
    final dill = p.join(workDir.path, '$name.dill');
    final res = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'kernel',
      '--packages=$pkgCfg',
      '-o',
      dill,
      script,
    ]);
    if (res.exitCode != 0) {
      throw StateError('Failed to compile $name: ${res.stderr}');
    }
    return dill;
  }

  return (
    v1ComplexityDill: await compile(
      v1PkgConfig,
      p.join(v1Bin, 'cognitive_complexity.dart'),
      'v1_cc',
    ),
    v2ComplexityDill: await compile(
      v2PkgConfig,
      p.join(v2Bin, 'cognitive_complexity.dart'),
      'v2_cc',
    ),
    v1ShallowDill: await compile(
      v1PkgConfig,
      p.join(v1Bin, 'shallow.dart'),
      'v1_shallow',
    ),
    v2ShallowDill: await compile(
      v2PkgConfig,
      p.join(v2Bin, 'shallow.dart'),
      'v2_shallow',
    ),
    v1FileSplitDill: await compile(
      v1PkgConfig,
      p.join(v1Bin, 'file_split.dart'),
      'v1_file_split',
    ),
    v2FileSplitDill: await compile(
      v2PkgConfig,
      p.join(v2Bin, 'file_split.dart'),
      'v2_file_split',
    ),
  );
}

String _writeBaselinePackageConfig({
  required String v2PkgConfigPath,
  required String v1PkgDir,
  required String outPath,
}) {
  final raw =
      jsonDecode(File(v2PkgConfigPath).readAsStringSync())
          as Map<String, dynamic>;
  final baseDir = p.dirname(v2PkgConfigPath);
  final pkgs = (raw['packages'] as List).cast<Map<String, dynamic>>();
  for (final pkg in pkgs) {
    if (pkg['name'] == 'cognitive_complexity') {
      pkg['rootUri'] = p.toUri(p.canonicalize(v1PkgDir)).toString();
    } else {
      final rootUri = pkg['rootUri'] as String;
      if (!rootUri.startsWith('file:')) {
        pkg['rootUri'] = p
            .toUri(p.normalize(p.join(baseDir, rootUri)))
            .toString();
      }
    }
  }
  File(outPath).writeAsStringSync(jsonEncode(raw));
  return outPath;
}

typedef _SweepTarget = ({String label, String path});

Future<List<_SweepTarget>> _resolveTargets({
  required String repoRoot,
  required String? reposDirOpt,
  required List<String> extraSpecs,
  required bool skipConsumers,
  required Directory workDir,
}) async {
  final targets = <_SweepTarget>[];
  if (!skipConsumers) {
    final siblingRoot = reposDirOpt ?? p.dirname(repoRoot);
    for (final repo in consumerRepos) {
      final localDir = Directory(p.join(siblingRoot, repo));
      if (localDir.existsSync()) {
        targets.add((label: repo, path: localDir.path));
      } else {
        final clonePath = p.join(workDir.path, 'repos', repo);
        final res = await Process.run('git', [
          'clone',
          '--depth=1',
          'https://github.com/kevmoo/$repo.git',
          clonePath,
        ]);
        if (res.exitCode == 0) {
          targets.add((label: repo, path: clonePath));
        }
      }
    }
  }
  for (final spec in extraSpecs) {
    final eq = spec.indexOf('=');
    if (eq > 0) {
      targets.add((
        label: spec.substring(0, eq),
        path: p.canonicalize(spec.substring(eq + 1)),
      ));
    }
  }
  return targets;
}

class _TargetCanaryResult {
  final String label;
  final String path;
  final List<String> crashes;
  final List<String> gateFlips;
  final List<String> ccDiffs;
  final List<String> shallowDiffs;
  final List<String> fileSplitDiffs;

  const _TargetCanaryResult({
    required this.label,
    required this.path,
    required this.crashes,
    required this.gateFlips,
    required this.ccDiffs,
    required this.shallowDiffs,
    required this.fileSplitDiffs,
  });

  Map<String, dynamic> toJson() => {
    'label': label,
    'path': path,
    'crashes': crashes,
    'gate_flips': gateFlips,
    'cc_diffs': ccDiffs,
    'shallow_diffs': shallowDiffs,
    'file_split_diffs': fileSplitDiffs,
  };
}

Future<_TargetCanaryResult> _sweepTarget(
  _SweepTarget target,
  _ToolSnapshots snaps,
) async {
  final crashes = <String>[];
  final gateFlips = <String>[];
  final (workDir, scanDirs) = _resolveScanContext(target.path);

  final v1Cc = await _runTool(snaps.v1ComplexityDill, [
    '--format=json',
    '--fail-threshold=15',
    ...scanDirs,
  ], workDir);
  final v2Cc = await _runTool(snaps.v2ComplexityDill, [
    '--format=json',
    '--fail-threshold=15',
    ...scanDirs,
  ], workDir);
  _checkCrashOrGateFlip(
    'cognitive_complexity',
    v1Cc,
    v2Cc,
    crashes,
    gateFlips,
    allowExit1: true,
  );
  final ccDiffs = _diffComplexityJson(v1Cc.stdout, v2Cc.stdout);

  final v1Sh = await _runTool(snaps.v1ShallowDill, [
    '--format=json',
    ...scanDirs,
  ], workDir);
  final v2Sh = await _runTool(snaps.v2ShallowDill, [
    '--format=json',
    ...scanDirs,
  ], workDir);
  _checkCrashOrGateFlip('shallow', v1Sh, v2Sh, crashes, gateFlips);
  final shallowDiffs = _diffShallowJson(v1Sh.stdout, v2Sh.stdout, gateFlips);

  final v1Fs = await _runTool(snaps.v1FileSplitDill, [
    '--format=json',
    ...scanDirs,
  ], workDir);
  final v2Fs = await _runTool(snaps.v2FileSplitDill, [
    '--format=json',
    ...scanDirs,
  ], workDir);
  _checkCrashOrGateFlip('file_split', v1Fs, v2Fs, crashes, gateFlips);
  final fileSplitDiffs = _diffFileSplitJson(
    v1Fs.stdout,
    v2Fs.stdout,
    gateFlips,
  );

  return _TargetCanaryResult(
    label: target.label,
    path: target.path,
    crashes: crashes,
    gateFlips: gateFlips,
    ccDiffs: ccDiffs,
    shallowDiffs: shallowDiffs,
    fileSplitDiffs: fileSplitDiffs,
  );
}

(String, List<String>) _resolveScanContext(String targetPath) {
  if (File(targetPath).existsSync()) {
    return (p.dirname(targetPath), [p.basename(targetPath)]);
  }
  final candidates = ['lib', 'bin', 'packages', 'pkgs'];
  final existing = [
    for (final c in candidates)
      if (Directory(p.join(targetPath, c)).existsSync()) c,
  ];
  return (targetPath, existing.isEmpty ? ['.'] : existing);
}

typedef _ToolRun = ({int exitCode, String stdout, String stderr});

Future<_ToolRun> _runTool(
  String dill,
  List<String> args,
  String workingDir,
) async {
  final res = await Process.run(
    Platform.resolvedExecutable,
    [dill, ...args],
    workingDirectory: workingDir,
    environment: {'GITHUB_WORKSPACE': ''},
  );
  return (
    exitCode: res.exitCode,
    stdout: (res.stdout as String).trim(),
    stderr: (res.stderr as String).trim(),
  );
}

void _checkCrashOrGateFlip(
  String tool,
  _ToolRun v1,
  _ToolRun v2,
  List<String> crashes,
  List<String> gateFlips, {
  bool allowExit1 = false,
}) {
  bool badExit(int code) => allowExit1 ? (code != 0 && code != 1) : code != 0;
  if (badExit(v1.exitCode)) {
    crashes.add('$tool v1 exited ${v1.exitCode}: ${v1.stderr}');
  }
  if (badExit(v2.exitCode)) {
    crashes.add('$tool v2 exited ${v2.exitCode}: ${v2.stderr}');
  }
  if (v1.exitCode != v2.exitCode) {
    gateFlips.add('$tool exit code flipped: ${v1.exitCode} -> ${v2.exitCode}');
  }
}

List<String> _diffComplexityJson(String v1Raw, String v2Raw) {
  if (v1Raw.isEmpty || v2Raw.isEmpty) return const [];
  final v1List = (jsonDecode(v1Raw) as List).cast<Map<String, dynamic>>();
  final v2List = (jsonDecode(v2Raw) as List).cast<Map<String, dynamic>>();
  final v1Map = {
    for (final d in v1List) '${d['file']}::${d['name']}': d['score'] as int,
  };
  final v2Map = {
    for (final d in v2List) '${d['file']}::${d['name']}': d['score'] as int,
  };
  final diffs = <String>[];
  for (final key in {...v1Map.keys, ...v2Map.keys}) {
    if (v1Map[key] != v2Map[key]) {
      diffs.add('`$key` score: ${v1Map[key]} -> ${v2Map[key]}');
    }
  }
  return diffs;
}

List<String> _diffShallowJson(
  String v1Raw,
  String v2Raw,
  List<String> gateFlips,
) {
  if (v1Raw.isEmpty || v2Raw.isEmpty) return const [];
  final v1 = jsonDecode(v1Raw) as Map<String, dynamic>;
  final v2 = jsonDecode(v2Raw) as Map<String, dynamic>;
  final s1 = v1['safe_inline_count'] as int? ?? 0;
  final s2 = v2['safe_inline_count'] as int? ?? 0;
  if ((s1 == 0) != (s2 == 0)) {
    gateFlips.add(
      'shallow --fail-on-safe-inline gate flipped '
      '(safe_inline_count: $s1 -> $s2)',
    );
  }
  final f1 = {
    for (final f in (v1['findings'] as List).cast<Map<String, dynamic>>())
      '${f['file']}::${f['name']}': f,
  };
  final f2 = {
    for (final f in (v2['findings'] as List).cast<Map<String, dynamic>>())
      '${f['file']}::${f['name']}': f,
  };
  final diffs = <String>[];
  for (final key in ({...f1.keys, ...f2.keys}.toList()..sort())) {
    final a = f1[key];
    final b = f2[key];
    final c1 = a?['classification'];
    final c2 = b?['classification'];
    if (c1 != c2) {
      final siblings = (b?['sibling_steps'] as List?)?.join(', ') ?? '';
      final note = siblings.isNotEmpty ? ' (siblings: [$siblings])' : '';
      diffs.add('`$key`: `$c1` -> `$c2`$note');
    }
  }
  return diffs;
}

List<String> _diffFileSplitJson(
  String v1Raw,
  String v2Raw,
  List<String> gateFlips,
) {
  if (v1Raw.isEmpty || v2Raw.isEmpty) return const [];
  final r1 = {
    for (final r in (jsonDecode(v1Raw) as List).cast<Map<String, dynamic>>())
      r['file'] as String: r,
  };
  final r2 = {
    for (final r in (jsonDecode(v2Raw) as List).cast<Map<String, dynamic>>())
      r['file'] as String: r,
  };
  final diffs = <String>[];
  for (final file in ({...r1.keys, ...r2.keys}.toList()..sort())) {
    final a = r1[file];
    final b = r2[file];
    if (a == null || b == null) continue;
    if (a['meets_target'] != b['meets_target']) {
      gateFlips.add(
        'file_split meets_target flipped on $file: '
        '${a['meets_target']} -> ${b['meets_target']}',
      );
    }
    diffs.addAll(_diffSingleFileSplit(file, a, b));
  }
  return diffs;
}

List<String> _diffSingleFileSplit(
  String file,
  Map<String, dynamic> a,
  Map<String, dynamic> b,
) {
  final c1 = (a['clusters'] as List).cast<Map<String, dynamic>>();
  final c2 = (b['clusters'] as List).cast<Map<String, dynamic>>();
  final files1 = [for (final c in c1) c['suggested_file'] as String];
  final files2 = [for (final c in c2) c['suggested_file'] as String];
  final diffs = <String>[];
  if (files1.join(',') != files2.join(',')) {
    diffs.add(
      '`$file` cut files: `[${files1.join(', ')}]` -> `[${files2.join(', ')}]`',
    );
  }
  for (var i = 0; i < c2.length; i++) {
    final cut2 = c2[i];
    final cut1 = i < c1.length ? c1[i] : null;
    final d1 = [
      for (final d in (cut1?['declarations'] as List? ?? const []))
        (d as Map)['name'],
    ].join(',');
    final d2 = [
      for (final d in (cut2['declarations'] as List)) (d as Map)['name'],
    ].join(',');
    if (d1 != d2) {
      diffs.add(
        '`$file` cut `${cut2['suggested_file']}` decls: `[$d1]` -> `[$d2]`',
      );
    }
    _appendCutDiagnostics(file, cut2, diffs);
  }
  return diffs;
}

void _appendCutDiagnostics(
  String file,
  Map<String, dynamic> cut2,
  List<String> diffs,
) {
  final suggested = cut2['suggested_file'];
  final notes = (cut2['notes'] as List?)?.cast<String>() ?? const [];
  final warnings = (cut2['warnings'] as List?)?.cast<String>() ?? const [];
  final cycles =
      (cut2['inherited_cycles'] as List?)?.cast<Map<String, dynamic>>() ??
      const [];
  for (final n in notes) {
    diffs.add('`$file` cut `$suggested` note: $n');
  }
  for (final w in warnings) {
    diffs.add('`$file` cut `$suggested` barrel warning: $w');
  }
  for (final c in cycles) {
    diffs.add(
      '`$file` cut `$suggested` inherited cycle: '
      '`${c['import']}` (via `${c['via']}`)',
    );
  }
}

String _renderCanaryReport({
  required List<_TargetCanaryResult> results,
  required String baselineRef,
}) {
  final allCrashes = [
    for (final r in results)
      for (final c in r.crashes) '- **`${r.label}`**: $c',
  ];
  final allGates = [
    for (final r in results)
      for (final g in r.gateFlips) '- **`${r.label}`**: $g',
  ];

  final buf = StringBuffer()
    ..writeln('# Cognitive Complexity Canary Report (`$baselineRef` vs `HEAD`)')
    ..writeln()
    ..writeln('Targets swept: **${results.length}**')
    ..writeln()
    ..writeln('## 1. Crashes')
    ..writeln()
    ..writeln(
      allCrashes.isEmpty
          ? 'None (0 crashes across ${results.length} targets).'
          : allCrashes.join('\n'),
    )
    ..writeln()
    ..writeln('## 2. Gate Flips')
    ..writeln()
    ..writeln(allGates.isEmpty ? 'None (0 gate flips).' : allGates.join('\n'))
    ..writeln()
    ..writeln('## 3. Finding Changes')
    ..writeln();

  _writeFindingChangesSection(results, buf);
  return buf.toString();
}

void _writeFindingChangesSection(
  List<_TargetCanaryResult> results,
  StringBuffer buf,
) {
  final withDiffs = results
      .where(
        (r) =>
            r.ccDiffs.isNotEmpty ||
            r.shallowDiffs.isNotEmpty ||
            r.fileSplitDiffs.isNotEmpty,
      )
      .toList();
  if (withDiffs.isEmpty) {
    buf.writeln('No finding changes across ${results.length} targets.');
    return;
  }
  for (final r in withDiffs) {
    buf.writeln('### `${r.label}`');
    _writeDiffLines(buf, 'complexity', r.ccDiffs);
    _writeDiffLines(buf, 'shallow', r.shallowDiffs);
    _writeDiffLines(buf, 'file_split', r.fileSplitDiffs);
    buf.writeln();
  }
}

void _writeDiffLines(StringBuffer buf, String tag, List<String> diffs) {
  for (final d in diffs) {
    buf.writeln('- **[$tag]** $d');
  }
}
