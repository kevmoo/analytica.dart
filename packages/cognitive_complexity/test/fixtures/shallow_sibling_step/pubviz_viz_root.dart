// Trimmed from kevmoo/pubviz `lib/src/viz_root.dart` at f50f9fb.
//
// Expected: `_filterIgnored`, `_filterStandard`, and `_filterIsolated` are
// SIBLING_STEP (`filter` caller dispatches to five `_filter*` steps; the
// `_filterWorkspace` / `_filterOutdated` steps are too complex to inline).
class VizPackage {
  final String name;
  final bool isPrimary;
  final bool isOutdated;
  final List<VizDependency> dependencies;

  VizPackage(this.name, this.dependencies, {this.isPrimary = false})
    : isOutdated = false;
}

class VizDependency {
  final String name;
  final bool isDevDependency;

  VizDependency(this.name, {this.isDevDependency = false});
}

class VizRoot {
  final String rootPackageName;
  final Map<String, VizPackage> packages;
  final bool isWorkspace;

  VizRoot(this.rootPackageName, this.packages, {this.isWorkspace = false});

  VizRoot filter({
    bool excludeDev = false,
    bool onlyOutdated = false,
    bool onlyWorkspace = false,
    bool hideIsolated = false,
    Iterable<String> ignorePackages = const [],
  }) {
    final ignored = ignorePackages.toSet();
    if (!excludeDev &&
        !onlyOutdated &&
        !onlyWorkspace &&
        !hideIsolated &&
        ignored.isEmpty) {
      return this;
    }

    var currentPackages = packages;
    if (ignored.isNotEmpty) {
      currentPackages = _filterIgnored(currentPackages, ignored);
    }
    if (onlyWorkspace) {
      currentPackages = _filterWorkspace(currentPackages, excludeDev);
    }
    if (onlyOutdated) {
      currentPackages = _filterOutdated(currentPackages, excludeDev);
    }
    if (!onlyWorkspace && !onlyOutdated) {
      currentPackages = _filterStandard(currentPackages, excludeDev);
    }

    if (hideIsolated && isWorkspace) {
      currentPackages = _filterIsolated(currentPackages);
    }

    return VizRoot(rootPackageName, currentPackages, isWorkspace: isWorkspace);
  }

  Map<String, VizPackage> _filterIgnored(
    Map<String, VizPackage> sourcePackages,
    Set<String> ignored,
  ) => _rebuildPackages(
    sourcePackages,
    sourcePackages.keys.where(
      (k) => k == rootPackageName || !ignored.contains(k),
    ),
    includeDep: (d) => !ignored.contains(d.name),
  );

  Map<String, VizPackage> _filterWorkspace(
    Map<String, VizPackage> sourcePackages,
    bool excludeDev,
  ) {
    final primaryNodes = _primaryPackageNames(sourcePackages);

    final forwardReachable = _reachable(
      primaryNodes,
      (pkg) => sourcePackages[pkg]?.dependencies
          .where((d) => !excludeDev || !d.isDevDependency)
          .map((d) => d.name),
    );

    final incoming = _buildIncoming(
      sourcePackages,
      forwardReachable,
      excludeDev: excludeDev,
    );

    final backwardReachable = _reachable(primaryNodes, (pkg) => incoming[pkg]);

    final keepNodes = forwardReachable.intersection(backwardReachable);

    return _rebuildPackages(
      sourcePackages,
      keepNodes,
      includeDep: (d) =>
          keepNodes.contains(d.name) && !(excludeDev && d.isDevDependency),
    );
  }

  Map<String, VizPackage> _filterOutdated(
    Map<String, VizPackage> sourcePackages,
    bool excludeDev,
  ) {
    final reachableFromRoot = _reachableFromRoots(
      sourcePackages,
      excludeDev: excludeDev,
    );

    final incoming = _buildIncoming(
      sourcePackages,
      reachableFromRoot,
      excludeDev: excludeDev,
    );

    final outdatedNodes = reachableFromRoot.where((name) {
      final p = sourcePackages[name];
      return p != null && p.isOutdated;
    }).toSet();

    final keepNodes = _reachable(outdatedNodes, (pkg) => incoming[pkg])
      ..add(rootPackageName);

    return _rebuildPackages(
      sourcePackages,
      keepNodes,
      includeDep: (d) =>
          keepNodes.contains(d.name) && (!excludeDev || !d.isDevDependency),
    );
  }

  Map<String, VizPackage> _filterStandard(
    Map<String, VizPackage> sourcePackages,
    bool excludeDev,
  ) {
    final keepNodes = _reachableFromRoots(
      sourcePackages,
      excludeDev: excludeDev,
    );

    return _rebuildPackages(
      sourcePackages,
      keepNodes,
      includeDep: (d) => !excludeDev || !d.isDevDependency,
    );
  }

  Map<String, VizPackage> _filterIsolated(
    Map<String, VizPackage> sourcePackages,
  ) {
    final keepNodes = _reachableFromPublished(rootPackageName, sourcePackages);
    return _rebuildPackages(
      sourcePackages,
      keepNodes,
      includeDep: (d) =>
          keepNodes.contains(d.name) && sourcePackages.containsKey(d.name),
    );
  }

  static Set<String> _primaryPackageNames(Map<String, VizPackage> packages) =>
      packages.values.where((p) => p.isPrimary).map((p) => p.name).toSet();

  Set<String> _reachableFromRoots(
    Map<String, VizPackage> sourcePackages, {
    required bool excludeDev,
  }) {
    final seeds = [..._primaryPackageNames(sourcePackages), rootPackageName];
    return _reachable(
      seeds,
      (pkg) => sourcePackages[pkg]?.dependencies
          .where((d) => !excludeDev || !d.isDevDependency)
          .map((d) => d.name),
    );
  }

  static Set<String> _reachableFromPublished(
    String root,
    Map<String, VizPackage> sourcePackages,
  ) => _reachable([
    root,
  ], (pkg) => sourcePackages[pkg]?.dependencies.map((d) => d.name));

  static Map<String, Set<String>> _buildIncoming(
    Map<String, VizPackage> sourcePackages,
    Set<String> nodes, {
    required bool excludeDev,
  }) {
    final incoming = <String, Set<String>>{};
    for (final name in nodes) {
      for (final dep
          in sourcePackages[name]?.dependencies ?? <VizDependency>[]) {
        if (excludeDev && dep.isDevDependency) continue;
        incoming.putIfAbsent(dep.name, () => {}).add(name);
      }
    }
    return incoming;
  }

  static Set<String> _reachable(
    Iterable<String> seeds,
    Iterable<String>? Function(String) next,
  ) {
    final seen = <String>{};
    final queue = [...seeds];
    while (queue.isNotEmpty) {
      final current = queue.removeLast();
      if (seen.add(current)) queue.addAll(next(current) ?? const []);
    }
    return seen;
  }

  static Map<String, VizPackage> _rebuildPackages(
    Map<String, VizPackage> sourcePackages,
    Iterable<String> keep, {
    required bool Function(VizDependency) includeDep,
  }) => {
    for (final name in keep)
      if (sourcePackages[name] case final pkg?)
        name: VizPackage(
          name,
          pkg.dependencies.where(includeDep).toList(),
          isPrimary: pkg.isPrimary,
        ),
  };
}
