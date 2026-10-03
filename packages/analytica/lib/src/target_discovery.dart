import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// Resolves the default `lib/` analysis targets for the project rooted at
/// [rootPath] (defaults to the current directory) when a CLI is invoked
/// without explicit positional targets.
///
/// Resolution order:
///
/// 1. A root `pubspec.yaml` declaring a `workspace:` list: every member
///    directory containing a `lib/` folder (plus the root `lib/` if present).
/// 2. A single-package layout: `lib/`.
/// 3. A conventional monorepo layout without a workspace declaration:
///    `packages/*/lib`, `pkgs/*/lib`, and `<dir>/lib` for any immediate
///    child directory containing a `pubspec.yaml`.
///
/// Returns `['lib']` when nothing matches so callers surface the same
/// "path does not exist" error as an explicit `lib` target. Returned paths are
/// relative to [rootPath] and sorted.
List<String> discoverDefaultTargets({String? rootPath}) {
  final root = rootPath ?? Directory.current.path;

  final workspaceTargets = _workspaceLibTargets(root);
  if (workspaceTargets.isNotEmpty) return workspaceTargets;

  if (Directory(p.join(root, 'lib')).existsSync()) return const ['lib'];

  final monorepoTargets = _monorepoLibTargets(root);
  if (monorepoTargets.isNotEmpty) return monorepoTargets;

  return const ['lib'];
}

List<String> _workspaceLibTargets(String root) {
  final members = _readWorkspaceMembers(File(p.join(root, 'pubspec.yaml')));
  if (members == null) return const [];

  final targets = <String>{
    if (Directory(p.join(root, 'lib')).existsSync()) 'lib',
    for (final member in members)
      if (Directory(p.join(root, member, 'lib')).existsSync())
        p.normalize(p.join(member, 'lib')),
  };
  return targets.toList()..sort();
}

/// Reads the `workspace:` member paths from [pubspec], or `null` if the file
/// is missing, unparsable, or declares no workspace.
List<String>? _readWorkspaceMembers(File pubspec) {
  if (!pubspec.existsSync()) return null;
  final Object? doc;
  try {
    doc = loadYaml(pubspec.readAsStringSync());
  } on YamlException {
    return null;
  }
  if (doc is! Map) return null;
  final workspace = doc['workspace'];
  if (workspace is! List) return null;
  return [
    for (final member in workspace)
      if (member is String) member,
  ];
}

List<String> _monorepoLibTargets(String root) {
  final targets = <String>{
    for (final container in const ['packages', 'pkgs'])
      ..._childLibDirs(root, container, requirePubspec: false),
    ..._childLibDirs(root, '.', requirePubspec: true),
  };
  return targets.toList()..sort();
}

/// Returns `<container>/<child>/lib` (relative to [root]) for each immediate
/// child directory of [container] that has a `lib/` folder, optionally
/// requiring a `pubspec.yaml` alongside it.
Iterable<String> _childLibDirs(
  String root,
  String container, {
  required bool requirePubspec,
}) sync* {
  final dir = Directory(p.join(root, container));
  if (!dir.existsSync()) return;
  for (final child in dir.listSync(followLinks: false)) {
    if (child is! Directory) continue;
    if (requirePubspec &&
        !File(p.join(child.path, 'pubspec.yaml')).existsSync()) {
      continue;
    }
    if (Directory(p.join(child.path, 'lib')).existsSync()) {
      yield p.normalize(p.join(container, p.basename(child.path), 'lib'));
    }
  }
}
