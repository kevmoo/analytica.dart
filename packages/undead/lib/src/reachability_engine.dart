import 'dart:io';

import 'package:analytica/analyzer.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart' hide WildcardPattern;
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:path/path.dart' as p;

import 'adapters/adapters.dart';
import 'ast_visitor.dart';
import 'comment_parser.dart';
import 'models.dart';
import 'root_harvester.dart';

/// Core reachability and dead declaration analysis engine for Dart packages.
class UndeadEngine {
  final UndeadOptions options;
  final List<WildcardPattern> _ignoreNameWildcards;
  final List<WildcardPattern> _testSupportWildcards;

  UndeadEngine(this.options)
    : _ignoreNameWildcards = options.ignoreNamePatterns
          .map(WildcardPattern.new)
          .toList(),
      _testSupportWildcards = options.testSupportPatterns
          .map(WildcardPattern.new)
          .toList();

  /// Performs reachability analysis on the target package.
  Future<UndeadReport> analyze() async {
    final harvester = RootHarvester(options);
    final topology = harvester.harvestTopology();
    final absolutePackagePath = p.normalize(p.absolute(options.packagePath));

    final contextHelper = _createContextHelper(
      absolutePackagePath: absolutePackagePath,
      topology: topology,
    );

    // Step 1: Single-pass parse and resolution for all files in topology.
    final data = await _harvestDeclarationsAndTestSites(
      contextHelper: contextHelper,
      topology: topology,
      absolutePackagePath: absolutePackagePath,
    );

    // Step 2: Connect reference edges and sealed hierarchies.
    final (crossLibraryReferenced, testReferencedIds) = _connectReferenceEdges(
      data: data,
      topology: topology,
    );

    // Step 3: Identify roots for Production and Tests.
    final (productionRoots, testRoots, exportedNodeIds) = await _identifyRoots(
      contextHelper: contextHelper,
      topology: topology,
      absolutePackagePath: absolutePackagePath,
      data: data,
      crossLibraryReferenced: crossLibraryReferenced,
    );

    // Step 4: Dual-Pass BFS Graph Traversal.
    final productionLive = _runBfs(
      startIds: productionRoots,
      idToNode: data.idToNode,
      sealedSubtypes: data.sealedSubtypes,
    );

    final testReachable = _runBfs(
      startIds: testRoots,
      idToNode: data.idToNode,
      sealedSubtypes: data.sealedSubtypes,
    );

    // Step 5: Candidate Classification and Hazard Detection.
    final classification = _classifyFindings(
      allNodes: data.allNodes,
      topology: topology,
      productionLive: productionLive,
      testReachable: testReachable,
      nodeDirectSuperElements: data.nodeDirectSuperElements,
      elementToNode: data.elementToNode,
      testSites: data.testSites,
    );

    final findings = classification.findings;
    var privateCandidates = 0;
    if (options.suggestPrivate) {
      final candidates = _collectPrivateCandidates(
        allNodes: data.allNodes,
        topology: topology,
        exportedNodeIds: exportedNodeIds,
        productionLive: productionLive,
        crossLibraryReferenced: crossLibraryReferenced,
        testReferencedIds: testReferencedIds,
      );
      privateCandidates = candidates.length;
      findings.addAll(candidates);
    }

    findings.sort(_compareFindings);

    return UndeadReport(
      version: '0.1.1-wip',
      package: topology.packageName,
      totalDeclarations: data.totalDeclarationsCount,
      pureUndeadFound: classification.pureUndead,
      testedUndeadFound: classification.testedUndead,
      coInvokedHazardsFound: classification.coInvokedHazards,
      privateCandidatesFound: privateCandidates,
      undead: findings,
    );
  }

  AnalysisContextHelper _createContextHelper({
    required String absolutePackagePath,
    required PackageTopology topology,
  }) {
    final extraPaths = <String>{};
    _collectExistingPaths(options.extraRoots, absolutePackagePath, extraPaths);
    _collectExistingPaths(
      topology.extraProductionFiles,
      absolutePackagePath,
      extraPaths,
    );
    _collectExistingPaths(
      topology.extraTestFiles,
      absolutePackagePath,
      extraPaths,
    );
    return AnalysisContextHelper(
      includedPaths: [absolutePackagePath, ...extraPaths],
      sdkPath: options.sdkPath,
    );
  }

  static void _collectExistingPaths(
    Iterable<String> paths,
    String basePath,
    Set<String> result,
  ) {
    for (final item in paths) {
      if (item.trim().isEmpty) continue;
      final resolved = p.normalize(
        p.isAbsolute(item) ? item : p.join(basePath, item),
      );
      if (FileSystemEntity.typeSync(resolved) !=
          FileSystemEntityType.notFound) {
        result.add(resolved);
      }
    }
  }

  Future<_HarvestedData> _harvestDeclarationsAndTestSites({
    required AnalysisContextHelper contextHelper,
    required PackageTopology topology,
    required String absolutePackagePath,
  }) async {
    final data = _HarvestedData();
    for (final relPath in topology.allFiles) {
      final absPath = p.normalize(
        p.isAbsolute(relPath) ? relPath : p.join(absolutePackagePath, relPath),
      );
      final unitResult = await contextHelper.getResolvedUnit(absPath);
      if (unitResult == null) continue;

      _processResolvedUnit(
        unitResult: unitResult,
        relPath: relPath,
        absPath: absPath,
        absolutePackagePath: absolutePackagePath,
        topology: topology,
        data: data,
      );
    }
    return data;
  }

  void _processResolvedUnit({
    required ResolvedUnitResult unitResult,
    required String relPath,
    required String absPath,
    required String absolutePackagePath,
    required PackageTopology topology,
    required _HarvestedData data,
  }) {
    final isFileIgnored = CommentParser.hasIgnoreForFile(unitResult.unit);
    final role = topology.roleOf(relPath);

    _collectConditionalImports(
      directives: unitResult.unit.directives,
      relPath: relPath,
      packageName: topology.packageName,
      conditionalTargets: data.conditionalTargets,
    );

    final fileDirectivesExtractor = ElementReferenceExtractor(
      absolutePackagePath,
    );
    for (final directive in unitResult.unit.directives) {
      if (directive is ExportDirective) {
        directive.accept(fileDirectivesExtractor);
      }
    }

    for (final decl in unitResult.unit.declarations) {
      if (decl is TopLevelVariableDeclaration) {
        _registerVariableDeclaration(
          decl: decl,
          unitResult: unitResult,
          relPath: relPath,
          absPath: absPath,
          absolutePackagePath: absolutePackagePath,
          isFileIgnored: isFileIgnored,
          fileDirectivesExtractor: fileDirectivesExtractor,
          data: data,
        );
      } else {
        _registerNonVariableDeclaration(
          decl: decl,
          unitResult: unitResult,
          relPath: relPath,
          absPath: absPath,
          absolutePackagePath: absolutePackagePath,
          isFileIgnored: isFileIgnored,
          fileDirectivesExtractor: fileDirectivesExtractor,
          data: data,
        );
      }
    }

    if (role == FileRole.test) {
      _extractTestSites(unitResult, relPath, absolutePackagePath, data);
    }
  }

  void _registerVariableDeclaration({
    required TopLevelVariableDeclaration decl,
    required ResolvedUnitResult unitResult,
    required String relPath,
    required String absPath,
    required String absolutePackagePath,
    required bool isFileIgnored,
    required ElementReferenceExtractor fileDirectivesExtractor,
    required _HarvestedData data,
  }) {
    final isExternalBinding = options.frameworkAdapter.isExternalBinding(
      decl,
      null,
    );
    final isNativeRoot =
        isNativeOrEntryPoint(decl) ||
        options.frameworkAdapter.isFrameworkEntryPoint(decl, null);

    for (final variable in decl.variables.variables) {
      data.totalDeclarationsCount++;
      final isVarIgnored =
          isFileIgnored ||
          CommentParser.isDeclarationIgnored(variable) ||
          CommentParser.isDeclarationIgnored(decl);
      final name =
          variable.declaredFragment?.element.name ?? variable.name.lexeme;
      final id = '$relPath#var#$name#${variable.offset}';
      final lineInfo = unitResult.lineInfo.getLocation(variable.offset);
      final element = variable.declaredFragment?.element;
      final isTestSupport = isTestSupportDeclaration(decl, name);

      final node = DeclarationNode(
        id: id,
        name: name,
        kind: DeclarationKind.variable,
        relativeFilePath: relPath,
        offset: variable.offset,
        length: variable.length,
        line: lineInfo.lineNumber,
        column: lineInfo.columnNumber,
        element: element,
        isIgnored: isVarIgnored,
        isTestSupport: isTestSupport,
        isExternalBinding:
            isExternalBinding ||
            options.frameworkAdapter.isExternalBinding(decl, element),
        isNativeRoot:
            isNativeRoot ||
            options.frameworkAdapter.isFrameworkEntryPoint(decl, element),
      );

      data.allNodes.add(node);
      data.idToNode[id] = node;
      data.locationToNode['${p.canonicalize(absPath)}#$name'] = node;
      _indexVariableElement(
        element: element,
        node: node,
        absPath: absPath,
        data: data,
      );

      final extractor = ElementReferenceExtractor(absolutePackagePath);
      decl.variables.type?.accept(extractor);
      for (final meta in decl.metadata) {
        meta.accept(extractor);
      }
      variable.accept(extractor);
      if (fileDirectivesExtractor.referencedTopLevelElements.isNotEmpty) {
        extractor.referencedTopLevelElements.addAll(
          fileDirectivesExtractor.referencedTopLevelElements,
        );
      }
      data.nodeOutboundElements[node] = extractor.referencedTopLevelElements;
    }
  }

  static void _indexVariableElement({
    required Element? element,
    required DeclarationNode node,
    required String absPath,
    required _HarvestedData data,
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

  void _registerNonVariableDeclaration({
    required Declaration decl,
    required ResolvedUnitResult unitResult,
    required String relPath,
    required String absPath,
    required String absolutePackagePath,
    required bool isFileIgnored,
    required ElementReferenceExtractor fileDirectivesExtractor,
    required _HarvestedData data,
  }) {
    data.totalDeclarationsCount++;
    final name = extractNodeName(decl) ?? 'anonymous';
    final (kind, isSealed) = _classifyDeclaration(decl);
    final id = '$relPath#${kind.jsonValue}#$name#${decl.offset}';
    final lineInfo = unitResult.lineInfo.getLocation(decl.offset);
    final element = decl.declaredFragment?.element;
    final isDeclIgnored =
        isFileIgnored || CommentParser.isDeclarationIgnored(decl);
    final isTestSupport = isTestSupportDeclaration(decl, name);
    final isExternalBinding = options.frameworkAdapter.isExternalBinding(
      decl,
      element,
    );
    final isNativeRoot =
        isNativeOrEntryPoint(decl) ||
        options.frameworkAdapter.isFrameworkEntryPoint(decl, element);

    final superElements = _extractSuperElements(element);

    final node = DeclarationNode(
      id: id,
      name: name,
      kind: kind,
      relativeFilePath: relPath,
      offset: decl.offset,
      length: decl.length,
      line: lineInfo.lineNumber,
      column: lineInfo.columnNumber,
      element: element,
      isIgnored: isDeclIgnored,
      isTestSupport: isTestSupport,
      isSealed: isSealed,
      isExternalBinding: isExternalBinding,
      isNativeRoot: isNativeRoot,
    );

    data.allNodes.add(node);
    data.idToNode[id] = node;
    data.locationToNode['${p.canonicalize(absPath)}#$name'] = node;
    if (element != null) {
      data.elementToNode[element] = node;
    }
    if (superElements.isNotEmpty) {
      data.nodeDirectSuperElements[node] = superElements;
    }

    final extractor = ElementReferenceExtractor(absolutePackagePath);
    decl.accept(extractor);
    if (fileDirectivesExtractor.referencedTopLevelElements.isNotEmpty) {
      extractor.referencedTopLevelElements.addAll(
        fileDirectivesExtractor.referencedTopLevelElements,
      );
    }
    data.nodeOutboundElements[node] = extractor.referencedTopLevelElements;
  }

  static List<Element> _extractSuperElements(Element? element) {
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

  void _extractTestSites(
    ResolvedUnitResult unitResult,
    String relPath,
    String absolutePackagePath,
    _HarvestedData data,
  ) {
    final visitor = _TestCallSiteVisitor(
      packageRoot: absolutePackagePath,
      relativeFilePath: relPath,
      lineInfo: unitResult.lineInfo,
      frameworkAdapter: options.frameworkAdapter,
    );
    unitResult.unit.accept(visitor);
    for (final entry in visitor.discoveredSites) {
      data.testSites.add(entry.site);
      data.testSiteRawElements[entry.site] = entry.referencedElements;
    }
  }

  (Set<String>, Set<String>) _connectReferenceEdges({
    required _HarvestedData data,
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

  static void _connectNodeOutboundEdges({
    required DeclarationNode node,
    required bool isTestNode,
    required _HarvestedData data,
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

  static void _connectNodeSuperEdges({
    required DeclarationNode node,
    required bool isTestNode,
    required _HarvestedData data,
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

  static void _connectConditionalImportEdges({
    required _HarvestedData data,
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

  static void _connectTestSiteEdges({
    required _HarvestedData data,
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

  Future<(Set<String>, Set<String>, Set<String>)> _identifyRoots({
    required AnalysisContextHelper contextHelper,
    required PackageTopology topology,
    required String absolutePackagePath,
    required _HarvestedData data,
    required Set<String> crossLibraryReferenced,
  }) async {
    final productionRoots = <String>{};
    final testRoots = <String>{};
    final exportedNodeIds = <String>{};

    await _harvestPublicApiRoots(
      contextHelper: contextHelper,
      topology: topology,
      absolutePackagePath: absolutePackagePath,
      data: data,
      productionRoots: productionRoots,
      exportedNodeIds: exportedNodeIds,
      crossLibraryReferenced: crossLibraryReferenced,
    );

    _harvestNonLibraryRoots(
      allNodes: data.allNodes,
      topology: topology,
      productionRoots: productionRoots,
      testRoots: testRoots,
    );

    return (productionRoots, testRoots, exportedNodeIds);
  }

  Future<void> _harvestPublicApiRoots({
    required AnalysisContextHelper contextHelper,
    required PackageTopology topology,
    required String absolutePackagePath,
    required _HarvestedData data,
    required Set<String> productionRoots,
    required Set<String> exportedNodeIds,
    required Set<String> crossLibraryReferenced,
  }) async {
    if (options.mode != AnalysisMode.library) return;

    for (final relPath in topology.publicLibFiles) {
      final absPath = p.join(absolutePackagePath, relPath);
      final unitResult = await contextHelper.getResolvedUnit(absPath);
      if (unitResult is ResolvedUnitResult) {
        _harvestExportedNamespace(
          unitResult.libraryElement,
          data,
          productionRoots,
          exportedNodeIds,
          crossLibraryReferenced,
        );
      }

      _addPublicNodesForFile(
        relPath,
        data.allNodes,
        productionRoots,
        exportedNodeIds,
        crossLibraryReferenced,
      );

      _harvestConditionalPublicTargets(
        relPath,
        data,
        productionRoots,
        exportedNodeIds,
        crossLibraryReferenced,
      );
    }
  }

  static void _harvestExportedNamespace(
    LibraryElement libElem,
    _HarvestedData data,
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

  static void _addPublicNodesForFile(
    String targetRelPath,
    List<DeclarationNode> allNodes,
    Set<String> productionRoots,
    Set<String> exportedNodeIds,
    Set<String> crossLibraryReferenced,
  ) {
    for (final node in allNodes) {
      if (node.relativeFilePath == targetRelPath &&
          !node.name.startsWith('_')) {
        _addPublicRoot(
          node.id,
          productionRoots,
          exportedNodeIds,
          crossLibraryReferenced,
        );
      }
    }
  }

  static void _harvestConditionalPublicTargets(
    String relPath,
    _HarvestedData data,
    Set<String> productionRoots,
    Set<String> exportedNodeIds,
    Set<String> crossLibraryReferenced,
  ) {
    final targets = data.conditionalTargets[relPath];
    if (targets == null) return;
    for (final targetRelPath in targets) {
      _addPublicNodesForFile(
        targetRelPath,
        data.allNodes,
        productionRoots,
        exportedNodeIds,
        crossLibraryReferenced,
      );
    }
  }

  static void _addPublicRoot(
    String id,
    Set<String> productionRoots,
    Set<String> exportedNodeIds,
    Set<String> crossLibraryReferenced,
  ) {
    productionRoots.add(id);
    exportedNodeIds.add(id);
    crossLibraryReferenced.add(id);
  }

  void _harvestNonLibraryRoots({
    required List<DeclarationNode> allNodes,
    required PackageTopology topology,
    required Set<String> productionRoots,
    required Set<String> testRoots,
  }) {
    for (final node in allNodes) {
      if (_isTestRoot(node, topology)) {
        testRoots.add(node.id);
      }
      if (_isExecutableRoot(node, topology) ||
          _isDemonstrationRoot(node, topology) ||
          _isAuxiliaryRoot(node, topology) ||
          _isConfigOrNativeRoot(node, topology) ||
          _isExtraProductionRoot(node, topology)) {
        productionRoots.add(node.id);
      }
    }
  }

  static bool _isExecutableRoot(
    DeclarationNode node,
    PackageTopology topology,
  ) {
    final isBinMain =
        topology.roleOf(node.relativeFilePath) == FileRole.executable &&
        node.name == 'main';
    final isFlutterMain =
        PackageTopology.isFlutterEntrypoint(node.relativeFilePath) &&
        node.name == 'main' &&
        topology.frameworkRoots.contains('main');
    return isBinMain || isFlutterMain;
  }

  bool _isDemonstrationRoot(DeclarationNode node, PackageTopology topology) {
    if (topology.roleOf(node.relativeFilePath) != FileRole.demonstration) {
      return false;
    }
    if (options.exampleMode == ExampleMode.demonstration) return true;
    if (options.exampleMode == ExampleMode.strict) return node.name == 'main';
    return false;
  }

  static bool _isAuxiliaryRoot(
    DeclarationNode node,
    PackageTopology topology,
  ) =>
      topology.roleOf(node.relativeFilePath) == FileRole.auxiliary &&
      node.name == 'main';

  static bool _isConfigOrNativeRoot(
    DeclarationNode node,
    PackageTopology topology,
  ) {
    if (node.isNativeRoot) return true;
    if (!topology.frameworkRoots.contains(node.name)) return false;
    return node.name != 'main' ||
        PackageTopology.isFlutterEntrypoint(node.relativeFilePath);
  }

  static bool _isExtraProductionRoot(
    DeclarationNode node,
    PackageTopology topology,
  ) => topology.extraProductionFiles.contains(node.relativeFilePath);

  static bool _isTestRoot(DeclarationNode node, PackageTopology topology) =>
      topology.roleOf(node.relativeFilePath) == FileRole.test;

  _ClassificationResult _classifyFindings({
    required List<DeclarationNode> allNodes,
    required PackageTopology topology,
    required Set<String> productionLive,
    required Set<String> testReachable,
    required Map<DeclarationNode, List<Element>> nodeDirectSuperElements,
    required Map<Element, DeclarationNode> elementToNode,
    required List<TestBlockSite> testSites,
  }) {
    final findings = <UndeadFinding>[];
    var pureUndead = 0;
    var testedUndead = 0;
    var coInvokedHazards = 0;

    for (final node in allNodes) {
      if (!_isUndeadCandidate(
        node,
        topology: topology,
        productionLive: productionLive,
        nodeDirectSuperElements: nodeDirectSuperElements,
        elementToNode: elementToNode,
      )) {
        continue;
      }

      if (!testReachable.contains(node.id)) {
        pureUndead++;
        findings.add(_createPureUndeadFinding(node));
      } else {
        final (finding, isHazard) = _classifyTestedNode(
          node,
          testSites: testSites,
          productionLive: productionLive,
        );
        if (finding == null) continue;
        if (isHazard) {
          coInvokedHazards++;
        } else {
          testedUndead++;
        }
        findings.add(finding);
      }
    }

    return _ClassificationResult(
      findings: findings,
      pureUndead: pureUndead,
      testedUndead: testedUndead,
      coInvokedHazards: coInvokedHazards,
    );
  }

  bool _isUndeadCandidate(
    DeclarationNode node, {
    required PackageTopology topology,
    required Set<String> productionLive,
    required Map<DeclarationNode, List<Element>> nodeDirectSuperElements,
    required Map<Element, DeclarationNode> elementToNode,
  }) {
    final role = topology.roleOf(node.relativeFilePath);
    if (!_isAnalysisCandidateScope(node, role)) return false;
    if (node.isIgnored) return false;
    if (options.ignoreExternalBindings && node.isExternalBinding) return false;
    if (WildcardPattern.anyMatch(_ignoreNameWildcards, node.name)) return false;
    if (productionLive.contains(node.id)) return false;
    if (_isDirectSubtypeOfLiveSealed(
      node,
      nodeDirectSuperElements: nodeDirectSuperElements,
      elementToNode: elementToNode,
      productionLive: productionLive,
    )) {
      return false;
    }
    return true;
  }

  bool _isAnalysisCandidateScope(DeclarationNode node, FileRole role) =>
      switch (role) {
        FileRole.internalSrc => true,
        FileRole.executable when node.name != 'main' => true,
        FileRole.auxiliary when node.name != 'main' => true,
        FileRole.demonstration
            when options.exampleMode == ExampleMode.strict &&
                node.name != 'main' =>
          true,
        FileRole.publicLib when options.mode == AnalysisMode.closedApp => true,
        _ => false,
      };

  static bool _isDirectSubtypeOfLiveSealed(
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

  static UndeadFinding _createPureUndeadFinding(DeclarationNode node) =>
      UndeadFinding(
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

  (UndeadFinding?, bool isHazard) _classifyTestedNode(
    DeclarationNode node, {
    required List<TestBlockSite> testSites,
    required Set<String> productionLive,
  }) {
    final isTestHook =
        node.isTestSupport ||
        WildcardPattern.anyMatch(_testSupportWildcards, node.name);
    if (isTestHook) return (null, false);

    final matchingSites = testSites
        .where((site) => site.referencedDeclarationIds.contains(node.id))
        .toList();

    final orphanSites = <OrphanTestSite>[];
    var hasCoInvokedHazard = false;

    for (final site in matchingSites) {
      final referencesLiveCode = site.referencedDeclarationIds.any(
        productionLive.contains,
      );
      if (referencesLiveCode) {
        hasCoInvokedHazard = true;
      }
      orphanSites.add(
        OrphanTestSite(
          file: site.relativeFilePath,
          line: site.line,
          column: site.column,
          description: site.description,
          coInvokedHazard: referencesLiveCode,
        ),
      );
    }

    final classification = hasCoInvokedHazard
        ? UndeadClassification.coInvokedHazard
        : UndeadClassification.testedUndead;
    final action = hasCoInvokedHazard
        ? SuggestedAction.manualRefactorHazard
        : SuggestedAction.deleteWithOrphanTests;

    return (
      UndeadFinding(
        id: node.name,
        name: node.name,
        kind: node.kind,
        file: node.relativeFilePath,
        line: node.line,
        column: node.column,
        length: node.length,
        classification: classification,
        suggestedAction: action,
        orphanTests: orphanSites.isNotEmpty ? orphanSites : null,
        isExternalBinding: node.isExternalBinding,
      ),
      hasCoInvokedHazard,
    );
  }

  static int _compareFindings(UndeadFinding a, UndeadFinding b) {
    final fileComp = a.file.compareTo(b.file);
    if (fileComp != 0) return fileComp;
    final lineComp = a.line.compareTo(b.line);
    if (lineComp != 0) return lineComp;
    return a.column.compareTo(b.column);
  }

  static Set<String> _extractDirectiveTargets(
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

  static void _collectConditionalImports({
    required List<Directive> directives,
    required String relPath,
    required String packageName,
    required Map<String, Set<String>> conditionalTargets,
  }) {
    for (final directive in directives) {
      if (directive is! NamespaceDirective ||
          directive.configurations.isEmpty) {
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

  static bool _isCrossLibrary(DeclarationNode source, DeclarationNode target) {
    final sourceLib = source.element?.library;
    final targetLib = target.element?.library;
    if (sourceLib != null && targetLib != null) {
      return sourceLib != targetLib;
    }
    return source.relativeFilePath != target.relativeFilePath;
  }

  static void _trackEdge(
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

  bool _isPrivateCandidate(
    DeclarationNode node, {
    required PackageTopology topology,
    required Set<String> exportedNodeIds,
    required Set<String> productionLive,
    required Set<String> crossLibraryReferenced,
    required Set<String> testReferencedIds,
  }) {
    final role = topology.roleOf(node.relativeFilePath);
    final isCandidateScope = switch (role) {
      FileRole.internalSrc => true,
      FileRole.publicLib when options.mode == AnalysisMode.closedApp => true,
      _ => false,
    };

    if (!isCandidateScope) return false;
    if (node.name.startsWith('_')) return false;
    if (node.isIgnored) return false;
    if (node.isNativeRoot) return false;
    if (node.isExternalBinding) return false;
    if (node.isTestSupport) return false;
    if (WildcardPattern.anyMatch(_ignoreNameWildcards, node.name)) return false;
    if (WildcardPattern.anyMatch(_testSupportWildcards, node.name)) {
      return false;
    }
    if (exportedNodeIds.contains(node.id)) return false;
    if (!productionLive.contains(node.id)) return false;
    if (crossLibraryReferenced.contains(node.id)) return false;
    if (testReferencedIds.contains(node.id)) return false;
    return true;
  }

  List<UndeadFinding> _collectPrivateCandidates({
    required List<DeclarationNode> allNodes,
    required PackageTopology topology,
    required Set<String> exportedNodeIds,
    required Set<String> productionLive,
    required Set<String> crossLibraryReferenced,
    required Set<String> testReferencedIds,
  }) => allNodes
      .where(
        (node) => _isPrivateCandidate(
          node,
          topology: topology,
          exportedNodeIds: exportedNodeIds,
          productionLive: productionLive,
          crossLibraryReferenced: crossLibraryReferenced,
          testReferencedIds: testReferencedIds,
        ),
      )
      .map(
        (node) => UndeadFinding(
          id: node.name,
          name: node.name,
          kind: node.kind,
          file: node.relativeFilePath,
          line: node.line,
          column: node.column,
          length: node.length,
          classification: UndeadClassification.privateCandidate,
          suggestedAction: SuggestedAction.makePrivate,
          isExternalBinding: node.isExternalBinding,
        ),
      )
      .toList();

  Set<String> _runBfs({
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

  static void _enqueueSealedSubtypes({
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

  (DeclarationKind, bool) _classifyDeclaration(Declaration decl) {
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

  static String? _resolveUri(
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
}

/// Harvested declaration, site, and element data accumulated during analysis.
class _HarvestedData {
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
class _ClassificationResult {
  final List<UndeadFinding> findings;
  final int pureUndead;
  final int testedUndead;
  final int coInvokedHazards;

  const _ClassificationResult({
    required this.findings,
    required this.pureUndead,
    required this.testedUndead,
    required this.coInvokedHazards,
  });
}

/// Discovered test invocation metadata.
class _DiscoveredSite {
  final TestBlockSite site;
  final Set<Element> referencedElements;

  const _DiscoveredSite({required this.site, required this.referencedElements});
}

/// Visitor that locates test invocations (`test(...)`, `testWidgets(...)`,
/// `solo_test(...)`) in test files and extracts elements referenced within
/// that specific leaf test block.
class _TestCallSiteVisitor extends RecursiveAstVisitor<void> {
  final String packageRoot;
  final String relativeFilePath;
  final LineInfo lineInfo;
  final FrameworkAdapter frameworkAdapter;
  final List<_DiscoveredSite> discoveredSites = [];

  _TestCallSiteVisitor({
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
      node.accept(extractor);

      final site = TestBlockSite(
        relativeFilePath: relativeFilePath,
        line: loc.lineNumber,
        column: loc.columnNumber,
        description: description,
      );

      discoveredSites.add(
        _DiscoveredSite(
          site: site,
          referencedElements: extractor.referencedTopLevelElements,
        ),
      );
    }
    super.visitMethodInvocation(node);
  }
}

/// Programmatic entrypoint function to analyze a package.
Future<UndeadReport> analyzePackage(
  String packagePath, {
  UndeadOptions? options,
}) async {
  final opts = options == null
      ? UndeadOptions(packagePath: packagePath)
      : (options.packagePath.isEmpty
            ? UndeadOptions(
                packagePath: packagePath,
                format: options.format,
                exampleMode: options.exampleMode,
                mode: options.mode,
                includeGenerated: options.includeGenerated,
                failOnUndead: options.failOnUndead,
                autoPubGet: options.autoPubGet,
                sdkPath: options.sdkPath,
                jsonOutputPath: options.jsonOutputPath,
                frameworkAdapter: options.frameworkAdapter,
                testSupportPatterns: options.testSupportPatterns,
                ignoreNamePatterns: options.ignoreNamePatterns,
                extraRoots: options.extraRoots,
                ignoreExternalBindings: options.ignoreExternalBindings,
                workspaceDiscovery: options.workspaceDiscovery,
                suggestPrivate: options.suggestPrivate,
              )
            : options);
  final engine = UndeadEngine(opts);
  return engine.analyze();
}
