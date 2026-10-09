// Trimmed from kevmoo/scripts.dart `lib/src/dart_clean.dart` at f97ecee.
//
// Expected: `_fetchPidAncestry` stays SAFE_INLINE (its caller calls no other
// `fetch*` helper).
typedef _PidAncestry = ({int pid, List<({int pid, String command})> ancestry});

abstract interface class ProcessInspector {
  Future<List<({int pid, String command})>> ancestry(int pid);
}

class DartProcess {
  final int pid;
  final int? ppid;
  final String cmdline;

  DartProcess(this.pid, this.ppid, this.cmdline);
}

class _ProcessNode {
  final int pid;
  final String cmdline;
  final int? parentPid;
  final List<_ProcessNode> children = [];
  List<({int pid, String command})> ancestry = const [];

  _ProcessNode({required this.pid, required this.cmdline, this.parentPid});
}

Future<int> countProcessTreeRoots(
  List<DartProcess> processes,
  ProcessInspector inspector,
) async => (await _buildTree(processes, inspector)).length;

Future<List<_ProcessNode>> _buildTree(
  List<DartProcess> processes,
  ProcessInspector inspector,
) async {
  final nodes = <int, _ProcessNode>{};

  for (final p in processes) {
    nodes[p.pid] = _ProcessNode(
      pid: p.pid,
      cmdline: p.cmdline,
      parentPid: p.ppid,
    );
  }

  final parentToPid = <int, int>{};
  for (final p in processes) {
    final ppid = p.ppid;
    if (ppid != null && ppid != 1 && !nodes.containsKey(ppid)) {
      parentToPid[ppid] = p.pid;
    }
  }

  final ancestriesList = await Future.wait(
    parentToPid.values.map((pid) => _fetchPidAncestry(pid, inspector)),
  );

  final ancestries = Map.fromEntries(
    ancestriesList.map((e) => MapEntry(e.pid, e.ancestry)),
  );

  return _linkProcessNodes(processes, nodes, ancestries);
}

Future<_PidAncestry> _fetchPidAncestry(
  int pid,
  ProcessInspector inspector,
) async {
  final ancestry = await inspector.ancestry(pid);
  return (pid: pid, ancestry: ancestry);
}

List<_ProcessNode> _linkProcessNodes(
  List<DartProcess> processes,
  Map<int, _ProcessNode> nodes,
  Map<int, List<({int pid, String command})>> ancestries,
) {
  final roots = <_ProcessNode>[];
  for (final p in processes) {
    final node = nodes[p.pid]!;
    final parent = nodes[p.ppid];
    if (parent != null) {
      parent.children.add(node);
      continue;
    }
    node.ancestry = ancestries[p.pid] ?? const [];
    roots.add(node);
  }
  return roots;
}
