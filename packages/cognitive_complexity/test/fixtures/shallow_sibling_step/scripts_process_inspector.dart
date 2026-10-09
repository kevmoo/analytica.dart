// Trimmed from kevmoo/scripts.dart `lib/src/process_inspector.dart` at
// f97ecee.
//
// Expected: `_readProcEnviron` is SIBLING_STEP (its siblings
// `_readProcCmdline` / `_readProcCwd` stay extracted).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class ProcessInfo {
  final int pid;
  final String cmdline;
  final String name;
  final List<String> env;
  final String? cwd;

  ProcessInfo({
    required this.pid,
    required this.cmdline,
    required this.name,
    required this.env,
    required this.cwd,
  });
}

class ProcFsProcessInspector {
  final String procPath;

  ProcFsProcessInspector({this.procPath = '/proc'});

  Future<ProcessInfo?> inspect(int pid) async {
    final pidDir = Directory('$procPath/$pid');
    if (!await pidDir.exists()) return null;

    final statContent = await _readProcString('$procPath/$pid/stat');
    if (statContent == null) return null;

    final commFile = await _readProcString('$procPath/$pid/comm');
    final name = (commFile != null && commFile.isNotEmpty)
        ? commFile
        : '<unknown>';

    final cmdline = await _readProcCmdline('$procPath/$pid/cmdline', name);
    final env = await _readProcEnviron('$procPath/$pid/environ');
    final cwd = await _readProcCwd('$procPath/$pid/cwd');

    return ProcessInfo(
      pid: pid,
      cmdline: cmdline,
      name: name,
      env: env,
      cwd: cwd,
    );
  }

  Future<String?> _readProcString(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      return (await file.readAsString()).trim();
    } catch (_) {
      return null;
    }
  }

  Future<String> _readProcCmdline(String path, String fallbackName) async {
    try {
      final file = File(path);
      if (!await file.exists()) return fallbackName;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return fallbackName;

      final parts = _splitNulSeparated(bytes);
      return parts.isNotEmpty ? parts.join(' ') : fallbackName;
    } catch (_) {
      return fallbackName;
    }
  }

  Future<List<String>> _readProcEnviron(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return const [];
      final bytes = await file.readAsBytes();
      return _splitNulSeparated(bytes);
    } catch (_) {
      return const [];
    }
  }

  Future<String?> _readProcCwd(String path) async {
    try {
      final link = Link(path);
      if (!await link.exists()) return null;
      var target = await link.target();
      const deletedSuffix = ' (deleted)';
      if (target.endsWith(deletedSuffix)) {
        target = target.substring(0, target.length - deletedSuffix.length);
      }
      return target;
    } catch (_) {
      return null;
    }
  }

  List<String> _splitNulSeparated(Uint8List bytes) {
    if (bytes.isEmpty) return const [];
    return utf8
        .decode(bytes, allowMalformed: true)
        .split('\u0000')
        .where((s) => s.isNotEmpty)
        .toList();
  }
}
