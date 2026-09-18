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

/// Computes the immediate dominator (idom) for each node in a DAG.
/// Returns a map from a node to its immediate dominator. If a node has no idom (it is a root), it maps to itself or is missing.
Map<int, int> computeImmediateDominators(int count, Map<int, Set<int>> dag) {
  // DAG can be sorted topologically.
  // In-degree array
  final inDegree = List<int>.filled(count, 0);
  final preds = <int, List<int>>{for (var i = 0; i < count; i++) i: []};
  for (final node in dag.keys) {
    for (final target in dag[node]!) {
      inDegree[target]++;
      preds[target]!.add(node);
    }
  }

  // Find natural roots (in-degree == 0).
  final roots = <int>[];
  for (var i = 0; i < count; i++) {
    if (inDegree[i] == 0) roots.add(i);
  }

  // To combine multiple roots for a single dominator tree, we use a virtual root `-1`.
  // doms maps node -> Set of dominators.
  final doms = <int, Set<int>>{};
  final allNodes = Set<int>.from(Iterable.generate(count))..add(-1);

  // Initialize: dom(root) = {root}, dom(other) = all_nodes
  doms[-1] = {-1};
  for (var i = 0; i < count; ++i) {
    doms[i] = allNodes;
  }
  for (final root in roots) {
    preds[root]!.add(-1);
  }

  // Topo sort
  final queue = List<int>.from(roots);
  final topo = <int>[];
  final inDegreeMutable = List<int>.from(inDegree);
  while (queue.isNotEmpty) {
    final curr = queue.removeLast();
    topo.add(curr);
    for (final next in dag[curr] ?? const <int>{}) {
      inDegreeMutable[next]--;
      if (inDegreeMutable[next] == 0) {
        queue.add(next);
      }
    }
  }

  // Forward pass to compute doms
  for (final node in topo) {
    if (preds[node]!.isEmpty) {
      doms[node] = {node};
    } else {
      var d = Set<int>.from(doms[preds[node]!.first]!);
      for (final p in preds[node]!.skip(1)) {
        d = d.intersection(doms[p]!);
      }
      d.add(node);
      doms[node] = d;
    }
  }

  // From dom sets, compute idom.
  // idom(n) is the unique dominator of n strictly dominating n, that is dominated by all other strict dominators of n.
  // In our dom set, idom(n) is the dominator of n (other than n) with the maximum |dom| size!
  final idom = <int, int>{};
  for (var i = 0; i < count; i++) {
    final strictDoms = doms[i]!.difference({i});
    if (strictDoms.isEmpty ||
        (strictDoms.length == 1 && strictDoms.first == -1)) {
      // no idom other than virtual root
      continue;
    }
    // Find the strict dom with the largest number of dominators
    var best = -1;
    var maxDomSize = -1;
    for (final d in strictDoms) {
      if (d == -1) continue;
      final size = doms[d]!.length;
      if (size > maxDomSize) {
        maxDomSize = size;
        best = d;
      }
    }
    if (best != -1) {
      idom[i] = best;
    }
  }
  return idom;
}
