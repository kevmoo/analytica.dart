/// Pure graph topology algorithms (Hard-Pin Contraction, Tarjan's Strongly
/// Connected Components, Condensation DAG, Topological Layer Depth, and LCOM4
/// Weakly Connected Components) for [DeclarationUnit] graphs.
library;

import 'dart:math' as math;

import 'models.dart';

/// Fuses declarations linked by [DeclarationUnit.hardPinnedPeers] (e.g.,
/// `sealed` classes with direct subtypes or `Widget` + `_WidgetState` pairs).
List<List<String>> fuseHardPinnedPeers(
  Map<String, DeclarationUnit> declsByName,
) {
  final visited = <String>{};
  final groups = <List<String>>[];

  for (final name in declsByName.keys) {
    if (!visited.add(name)) continue;
    groups.add(_collectConnectedPeers(name, declsByName, visited));
  }
  return groups;
}

List<String> _collectConnectedPeers(
  String start,
  Map<String, DeclarationUnit> declsByName,
  Set<String> visited,
) {
  final group = <String>[start];
  final queue = <String>[start];
  while (queue.isNotEmpty) {
    final curr = queue.removeLast();
    final peers = declsByName[curr]?.hardPinnedPeers ?? const {};
    for (final p in peers) {
      if (visited.add(p)) {
        group.add(p);
        queue.add(p);
      }
    }
  }
  return group;
}

/// Computes Tarjan's Strongly Connected Components over [pinnedGroups].
List<List<String>> computeTarjanSccs(
  List<List<String>> pinnedGroups,
  Map<String, DeclarationUnit> declsByName,
) {
  final adj = _buildGroupAdjacency(pinnedGroups, declsByName);
  final state = _TarjanState(pinnedGroups);
  for (var i = 0; i < pinnedGroups.length; i++) {
    if (!state.indices.containsKey(i)) {
      state.strongConnect(i, adj);
    }
  }
  return state.sccs;
}

Map<int, Set<int>> _buildGroupAdjacency(
  List<List<String>> groups,
  Map<String, DeclarationUnit> declsByName,
) {
  final nameToIdx = <String, int>{
    for (var i = 0; i < groups.length; i++)
      for (final name in groups[i]) name: i,
  };
  final adj = <int, Set<int>>{
    for (var i = 0; i < groups.length; i++) i: <int>{},
  };
  for (var i = 0; i < groups.length; i++) {
    for (final name in groups[i]) {
      final refs = declsByName[name]?.outgoingIntraFileRefs ?? const {};
      adj[i]!.addAll(
        refs.map((r) => nameToIdx[r]).whereType<int>().where((idx) => idx != i),
      );
    }
  }
  return adj;
}

class _TarjanState {
  final List<List<String>> groups;
  int index = 0;
  final indices = <int, int>{};
  final lowlink = <int, int>{};
  final stack = <int>[];
  final onStack = <int>{};
  final sccs = <List<String>>[];

  _TarjanState(this.groups);

  void strongConnect(int v, Map<int, Set<int>> adj) {
    indices[v] = index;
    lowlink[v] = index;
    index++;
    stack.add(v);
    onStack.add(v);

    for (final w in adj[v] ?? const <int>{}) {
      _visitNeighbor(v, w, adj);
    }

    if (lowlink[v] == indices[v]) {
      _popScc(v);
    }
  }

  void _visitNeighbor(int v, int w, Map<int, Set<int>> adj) {
    if (!indices.containsKey(w)) {
      strongConnect(w, adj);
      lowlink[v] = math.min(lowlink[v]!, lowlink[w]!);
    } else if (onStack.contains(w)) {
      lowlink[v] = math.min(lowlink[v]!, indices[w]!);
    }
  }

  void _popScc(int root) {
    final merged = <String>[];
    while (true) {
      final w = stack.removeLast();
      onStack.remove(w);
      merged.addAll(groups[w]);
      if (w == root) break;
    }
    sccs.add(merged);
  }
}

/// Builds the acyclic Condensation DAG over [sccs].
Map<int, Set<int>> buildCondensationDag(
  List<List<String>> sccs,
  Map<String, DeclarationUnit> declsByName,
) {
  return _buildGroupAdjacency(sccs, declsByName);
}

/// Computes the topological layer depth for each node in [dag] (`0` = leaf).
Map<int, int> computeTopologicalDepths(int count, Map<int, Set<int>> dag) {
  final memo = <int, int>{};
  int depthOf(int node) {
    final cached = memo[node];
    if (cached != null) return cached;
    final children = dag[node] ?? const <int>{};
    if (children.isEmpty) return memo[node] = 0;
    return memo[node] = 1 + children.map(depthOf).fold(0, math.max);
  }

  for (var i = 0; i < count; i++) {
    depthOf(i);
  }
  return memo;
}

/// Computes Weakly Connected Components (LCOM4 islands) of [dag].
List<Set<int>> computeWeaklyConnectedIslands(
  int count,
  Map<int, Set<int>> dag,
) {
  final undirected = _toUndirectedGraph(count, dag);
  final visited = <int>{};
  final islands = <Set<int>>[];

  for (var i = 0; i < count; i++) {
    if (!visited.add(i)) continue;
    islands.add(_bfsIsland(i, undirected, visited));
  }
  return islands;
}

Map<int, Set<int>> _toUndirectedGraph(int count, Map<int, Set<int>> dag) {
  final undirected = <int, Set<int>>{
    for (var i = 0; i < count; i++) i: <int>{},
  };
  for (final entry in dag.entries) {
    for (final target in entry.value) {
      undirected[entry.key]!.add(target);
      undirected[target]!.add(entry.key);
    }
  }
  return undirected;
}

Set<int> _bfsIsland(
  int start,
  Map<int, Set<int>> undirected,
  Set<int> visited,
) {
  final comp = <int>{start};
  final queue = <int>[start];
  while (queue.isNotEmpty) {
    final curr = queue.removeLast();
    for (final next in undirected[curr]!) {
      if (visited.add(next)) {
        comp.add(next);
        queue.add(next);
      }
    }
  }
  return comp;
}
