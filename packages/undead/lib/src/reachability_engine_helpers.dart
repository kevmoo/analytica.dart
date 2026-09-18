import 'dart:io';

import 'package:analytica/analyzer.dart';
import 'package:analyzer/dart/ast/ast.dart' hide WildcardPattern;
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:path/path.dart' as p;

import 'adapters/adapters.dart';
import 'models.dart';
import 'root_harvester.dart';

void collectExistingPaths(
  Iterable<String> paths,
  String basePath,
  Set<String> result,
) {
  for (final item in paths) {
    if (item.trim().isEmpty) continue;
    final resolved = p.normalize(
      p.isAbsolute(item) ? item : p.join(basePath, item),
    );
    if (FileSystemEntity.typeSync(resolved) != FileSystemEntityType.notFound) {
      result.add(resolved);
    }
  }
}

void indexVariableElement({
  required Element? element,
  required DeclarationNode node,
  required String absPath,
  required HarvestedData data,
}) {
  if (element == null) return;
  data.elementToNode[element] = node;
  if (element is! TopLevelVariableElement) return;

  final getter = element.getter;
  if (getter != null) {
    data.elementToNode[getter] = node;
    final getterKey = '${p.canonicalize(absPath)}#${getter.name}';
    data.locationToNode[getterKey] = node;
  }
  final setter = element.setter;
  if (setter != null) {
    data.elementToNode[setter] = node;
    final setterKey = '${p.canonicalize(absPath)}#${setter.name}';
    data.locationToNode[setterKey] = node;
  }
}

List<Element> extractSuperElements(Element? element) {
  if (element is! InterfaceElement) return const [];
  final superElements = <Element>[];
  final supertype = element.supertype;
  if (supertype != null) superElements.add(supertype.element);
  for (final iface in element.interfaces) {
    superElements.add(iface.element);
  }
  for (final mixinType in element.mixins) {
    superElements.add(mixinType.element);
  }
  return superElements;
}

(Set<String>, Set<String>) connectReferenceEdges({
  required HarvestedData data,
  required PackageTopology topology,
}) {
  final crossLibraryReferenced = <String>{};
  final testReferencedIds = <String>{};

  for (final node in data.allNodes) {
    final isTestNode =
        topology.roleOf(node.relativeFilePath) == FileRole.test ||
        topology.extraTestFiles.contains(node.relativeFilePath);

    _connectNodeOutboundEdges(
      node: node,
      isTestNode: isTestNode,
      data: data,
      crossLibraryReferenced: crossLibraryReferenced,
      testReferencedIds: testReferencedIds,
    );

    _connectNodeSuperEdges(
      node: node,
      isTestNode: isTestNode,
      data: data,
      crossLibraryReferenced: crossLibraryReferenced,
      testReferencedIds: testReferencedIds,
    );
  }

  _connectConditionalImportEdges(
    data: data,
    crossLibraryReferenced: crossLibraryReferenced,
  );

  _connectTestSiteEdges(
    data: data,
    crossLibraryReferenced: crossLibraryReferenced,
    testReferencedIds: testReferencedIds,
  );

  return (crossLibraryReferenced, testReferencedIds);
}

void _connectNodeOutboundEdges({
  required DeclarationNode node,
  required bool isTestNode,
  required HarvestedData data,
  required Set<String> crossLibraryReferenced,
  required Set<String> testReferencedIds,
}) {
  final outbound = data.nodeOutboundElements[node];
  if (outbound == null) return;
  for (final refElem in outbound) {
    final targetNode = data.resolveNodeForElement(refElem);
    if (targetNode != null && targetNode.id != node.id) {
      node.outgoingTargetIds.add(targetNode.id);
      _trackEdge(
        node,
        targetNode,
        isTestNode: isTestNode,
        crossLibraryReferenced: crossLibraryReferenced,
        testReferencedIds: testReferencedIds,
      );
    }
  }
}

void _connectNodeSuperEdges({
  required DeclarationNode node,
  required bool isTestNode,
  required HarvestedData data,
  required Set<String> crossLibraryReferenced,
  required Set<String> testReferencedIds,
}) {
  final superElems = data.nodeDirectSuperElements[node];
  if (superElems == null) return;
  for (final superElem in superElems) {
    final parentNode = data.resolveNodeForElement(superElem);
    if (parentNode == null) continue;
    if (parentNode.isSealed) {
      data.sealedSubtypes.putIfAbsent(parentNode.id, () => {}).add(node.id);
    }
    _trackEdge(
      node,
      parentNode,
      isTestNode: isTestNode,
      crossLibraryReferenced: crossLibraryReferenced,
      testReferencedIds: testReferencedIds,
    );
  }
}

void _connectConditionalImportEdges({
  required HarvestedData data,
  required Set<String> crossLibraryReferenced,
}) {
  for (final entry in data.conditionalTargets.entries) {
    final sourceRelPath = entry.key;
    final targetRelPaths = entry.value;
    final sourceNodes = data.allNodes
        .where((n) => n.relativeFilePath == sourceRelPath)
        .toList();
    final targetNodes = data.allNodes
        .where((n) => targetRelPaths.contains(n.relativeFilePath))
        .toList();
    for (final sourceNode in sourceNodes) {
      for (final targetNode in targetNodes) {
        sourceNode.outgoingTargetIds.add(targetNode.id);
        crossLibraryReferenced.add(targetNode.id);
      }
    }
  }
}

void _connectTestSiteEdges({
  required HarvestedData data,
  required Set<String> crossLibraryReferenced,
  required Set<String> testReferencedIds,
}) {
  for (final site in data.testSites) {
    final rawElems = data.testSiteRawElements[site];
    if (rawElems == null) continue;
    for (final elem in rawElems) {
      final targetNode = data.resolveNodeForElement(elem);
      if (targetNode != null) {
        site.referencedDeclarationIds.add(targetNode.id);
        testReferencedIds.add(targetNode.id);
        crossLibraryReferenced.add(targetNode.id);
      }
    }
  }
}

void harvestExportedNamespace(
  LibraryElement libElem,
  HarvestedData data,
  Set<String> productionRoots,
  Set<String> exportedNodeIds,
  Set<String> crossLibraryReferenced,
) {
  for (final exportedElem in libElem.exportNamespace.definedNames2.values) {
    final topLevel = getTopLevelElement(exportedElem);
    if (topLevel != null) {
      final node = data.elementToNode[topLevel];
      if (node != null) {
        _addPublicRoot(
          node.id,
          productionRoots,
          exportedNodeIds,
          crossLibraryReferenced,
        );
      }
    }
  }
}

void addPublicNodesForFile(
  String targetRelPath,
  List<DeclarationNode> allNodes,
  Set<String> productionRoots,
  Set<String> exportedNodeIds,
  Set<String> crossLibraryReferenced,
) {
  for (final node in allNodes) {
    if (node.relativeFilePath == targetRelPath && !node.name.startsWith('_')) {
      _addPublicRoot(
        node.id,
        productionRoots,
        exportedNodeIds,
        crossLibraryReferenced,
      );
    }
  }
}

void harvestConditionalPublicTargets(
  String relPath,
  HarvestedData data,
  Set<String> productionRoots,
  Set<String> exportedNodeIds,
  Set<String> crossLibraryReferenced,
) {
  final targets = data.conditionalTargets[relPath];
  if (targets == null) return;
  for (final targetRelPath in targets) {
    addPublicNodesForFile(
      targetRelPath,
      data.allNodes,
      productionRoots,
      exportedNodeIds,
      crossLibraryReferenced,
    );
  }
}

void _addPublicRoot(
  String id,
  Set<String> productionRoots,
  Set<String> exportedNodeIds,
  Set<String> crossLibraryReferenced,
) {
  productionRoots.add(id);
  exportedNodeIds.add(id);
  crossLibraryReferenced.add(id);
}

bool isExecutableRoot(DeclarationNode node, PackageTopology topology) {
  final isBinMain =
      topology.roleOf(node.relativeFilePath) == FileRole.executable &&
      node.name == 'main';
  final isFlutterMain =
      PackageTopology.isFlutterEntrypoint(node.relativeFilePath) &&
      node.name == 'main' &&
      topology.frameworkRoots.contains('main');
  return isBinMain || isFlutterMain;
}

bool isAuxiliaryRoot(DeclarationNode node, PackageTopology topology) =>
    topology.roleOf(node.relativeFilePath) == FileRole.auxiliary &&
    node.name == 'main';

bool isConfigOrNativeRoot(DeclarationNode node, PackageTopology topology) {
  if (node.isNativeRoot) return true;
  if (!topology.frameworkRoots.contains(node.name)) return false;
  return node.name != 'main' ||
      PackageTopology.isFlutterEntrypoint(node.relativeFilePath);
}

bool isExtraProductionRoot(DeclarationNode node, PackageTopology topology) =>
    topology.extraProductionFiles.contains(node.relativeFilePath);

bool isTestRoot(DeclarationNode node, PackageTopology topology) =>
    topology.roleOf(node.relativeFilePath) == FileRole.test;

bool isDirectSubtypeOfLiveSealed(
  DeclarationNode node, {
  required Map<DeclarationNode, List<Element>> nodeDirectSuperElements,
  required Map<Element, DeclarationNode> elementToNode,
  required Set<String> productionLive,
}) {
  final superElems = nodeDirectSuperElements[node];
  if (superElems == null) return false;
  for (final superElem in superElems) {
    final parentNode = elementToNode[superElem];
    if (parentNode != null &&
        parentNode.isSealed &&
        productionLive.contains(parentNode.id)) {
      return true;
    }
  }
  return false;
}

UndeadFinding createPureUndeadFinding(DeclarationNode node) => UndeadFinding(
  id: node.name,
  name: node.name,
  kind: node.kind,
  file: node.relativeFilePath,
  line: node.line,
  column: node.column,
  length: node.length,
  classification: UndeadClassification.pureUndead,
  suggestedAction: SuggestedAction.delete,
  isExternalBinding: node.isExternalBinding,
);

int compareFindings(UndeadFinding a, UndeadFinding b) {
  final fileComp = a.file.compareTo(b.file);
  if (fileComp != 0) return fileComp;
  final lineComp = a.line.compareTo(b.line);
  if (lineComp != 0) return lineComp;
  return a.column.compareTo(b.column);
}

Set<String> _extractDirectiveTargets(
  NamespaceDirective directive,
  String relPath,
  String packageName,
) {
  final targets = <String>{};
  final defaultUri = directive.uri.stringValue;
  if (defaultUri != null && defaultUri.isNotEmpty) {
    final resolved = _resolveUri(relPath, defaultUri, packageName);
    if (resolved != null) {
      targets.add(resolved);
    }
  }
  for (final config in directive.configurations) {
    final uriStr = config.uri.stringValue;
    if (uriStr != null && uriStr.isNotEmpty) {
      final resolved = _resolveUri(relPath, uriStr, packageName);
      if (resolved != null) {
        targets.add(resolved);
      }
    }
  }
  return targets;
}

void collectConditionalImports({
  required List<Directive> directives,
  required String relPath,
  required String packageName,
  required Map<String, Set<String>> conditionalTargets,
}) {
  for (final directive in directives) {
    if (directive is! NamespaceDirective || directive.configurations.isEmpty) {
      continue;
    }
    final targets = _extractDirectiveTargets(directive, relPath, packageName);
    if (targets.isEmpty) continue;

    final allGroupFiles = {relPath, ...targets};
    for (final file in allGroupFiles) {
      conditionalTargets
          .putIfAbsent(file, () => {})
          .addAll(allGroupFiles.where((f) => f != file));
    }
  }
}

bool _isCrossLibrary(DeclarationNode source, DeclarationNode target) {
  final sourceLib = source.element?.library;
  final targetLib = target.element?.library;
  if (sourceLib != null && targetLib != null) {
    return sourceLib != targetLib;
  }
  return source.relativeFilePath != target.relativeFilePath;
}

void _trackEdge(
  DeclarationNode source,
  DeclarationNode target, {
  required bool isTestNode,
  required Set<String> crossLibraryReferenced,
  required Set<String> testReferencedIds,
}) {
  if (isTestNode) {
    testReferencedIds.add(target.id);
    crossLibraryReferenced.add(target.id);
  } else if (_isCrossLibrary(source, target)) {
    crossLibraryReferenced.add(target.id);
  }
}

Set<String> runBfs({
  required Set<String> startIds,
  required Map<String, DeclarationNode> idToNode,
  required Map<String, Set<String>> sealedSubtypes,
}) {
  final visited = <String>{...startIds};
  final queue = <String>[...startIds];
  var head = 0;

  while (head < queue.length) {
    final currentId = queue[head++];
    final node = idToNode[currentId];
    if (node == null) continue;

    for (final targetId in node.outgoingTargetIds) {
      if (visited.add(targetId)) {
        queue.add(targetId);
      }
    }

    if (node.isSealed) {
      _enqueueSealedSubtypes(
        currentId: currentId,
        sealedSubtypes: sealedSubtypes,
        visited: visited,
        queue: queue,
      );
    }
  }

  return visited;
}

void _enqueueSealedSubtypes({
  required String currentId,
  required Map<String, Set<String>> sealedSubtypes,
  required Set<String> visited,
  required List<String> queue,
}) {
  final subtypes = sealedSubtypes[currentId];
  if (subtypes == null) return;
  for (final subId in subtypes) {
    if (visited.add(subId)) {
      queue.add(subId);
    }
  }
}

(DeclarationKind, bool) classifyDeclaration(Declaration decl) {
  if (decl is ClassDeclaration) {
    return (DeclarationKind.classType, decl.sealedKeyword != null);
  }
  if (decl is ClassTypeAlias) {
    return (DeclarationKind.classType, false);
  }
  if (decl is EnumDeclaration) {
    return (DeclarationKind.enumType, false);
  }
  if (decl is MixinDeclaration) {
    return (DeclarationKind.mixinType, false);
  }
  if (decl is ExtensionDeclaration) {
    return (DeclarationKind.extension, false);
  }
  if (decl is ExtensionTypeDeclaration) {
    return (DeclarationKind.extensionType, false);
  }
  if (decl is TypeAlias) {
    return (DeclarationKind.typedefType, false);
  }
  if (decl is FunctionDeclaration) {
    if (decl.isGetter) return (DeclarationKind.getter, false);
    if (decl.isSetter) return (DeclarationKind.setter, false);
    return (DeclarationKind.function, false);
  }
  return (DeclarationKind.function, false);
}

String? _resolveUri(
  String currentRelPath,
  String uriString,
  String packageName,
) {
  if (uriString.startsWith('package:')) {
    final prefix = 'package:$packageName/';
    if (uriString.startsWith(prefix)) {
      final rest = uriString.substring(prefix.length);
      return p.normalize(p.join('lib', rest));
    }
    return null;
  }
  if (uriString.startsWith('dart:')) {
    return null;
  }
  final currentDir = p.dirname(currentRelPath);
  return p.normalize(p.join(currentDir, uriString));
}

/// Harvested declaration, site, and element data accumulated during analysis.
class HarvestedData {
  final List<DeclarationNode> allNodes = [];
  final Map<Element, DeclarationNode> elementToNode = {};
  final Map<String, DeclarationNode> locationToNode = {};
  final Map<String, DeclarationNode> idToNode = {};
  final List<TestBlockSite> testSites = [];
  final Map<TestBlockSite, Set<Element>> testSiteRawElements = {};
  final Map<DeclarationNode, Set<Element>> nodeOutboundElements = {};
  final Map<DeclarationNode, List<Element>> nodeDirectSuperElements = {};
  final Map<String, Set<String>> sealedSubtypes = {};
  final Map<String, Set<String>> conditionalTargets = {};
  int totalDeclarationsCount = 0;

  DeclarationNode? resolveNodeForElement(Element elem) {
    final direct = elementToNode[elem];
    if (direct != null) return direct;

    final sourcePath =
        elem.library?.firstFragment.source.fullName ??
        elem.firstFragment.libraryFragment?.source.fullName;
    if (sourcePath == null) return null;

    final canonicalPath = p.canonicalize(sourcePath);
    final name = elem.name;
    if (name != null) {
      final match = locationToNode['$canonicalPath#$name'];
      if (match != null) return match;
    }

    final topLevel = getTopLevelElement(elem);
    if (topLevel != null && topLevel.name != null) {
      final match = locationToNode['$canonicalPath#${topLevel.name}'];
      if (match != null) return match;
    }

    return null;
  }
}

/// Result of classifying candidates into undead categories.
class ClassificationResult {
  final List<UndeadFinding> findings;
  final int pureUndead;
  final int testedUndead;
  final int coInvokedHazards;

  const ClassificationResult({
    required this.findings,
    required this.pureUndead,
    required this.testedUndead,
    required this.coInvokedHazards,
  });
}

/// Discovered test invocation metadata.
class DiscoveredSite {
  final TestBlockSite site;
  final Set<Element> referencedElements;

  const DiscoveredSite({required this.site, required this.referencedElements});
}

/// Visitor that locates test invocations (`test(...)`, `testWidgets(...)`,
/// `solo_test(...)`) in test files and extracts elements referenced within
/// that specific leaf test block.
class TestCallSiteVisitor extends RecursiveAstVisitor<void> {
  final String packageRoot;
  final String relativeFilePath;
  final LineInfo lineInfo;
  final FrameworkAdapter frameworkAdapter;
  final List<DiscoveredSite> discoveredSites = [];

  TestCallSiteVisitor({
    required this.packageRoot,
    required this.relativeFilePath,
    required this.lineInfo,
    required this.frameworkAdapter,
  });

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final isTestFn = frameworkAdapter.isTestCallSite(node);
    final isFixtureFn = frameworkAdapter.isTestHarnessSite(node);

    if (isTestFn || isFixtureFn) {
      final loc = lineInfo.getLocation(node.offset);
      String? description;
      if (node.argumentList.arguments.isNotEmpty) {
        final firstArg = node.argumentList.arguments.first;
        if (firstArg is SimpleStringLiteral) {
          description = firstArg.value;
        } else if (firstArg is StringLiteral) {
          description = firstArg.stringValue;
        }
      }
      description ??= isFixtureFn ? node.methodName.name : null;

      final extractor = ElementReferenceExtractor(packageRoot);
      node.accept<void>(extractor);

      final site = TestBlockSite(
        relativeFilePath: relativeFilePath,
        line: loc.lineNumber,
        column: loc.columnNumber,
        description: description,
      );

      discoveredSites.add(
        DiscoveredSite(
          site: site,
          referencedElements: extractor.referencedTopLevelElements,
        ),
      );
    }
    super.visitMethodInvocation(node);
  }
}
