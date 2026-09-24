import 'package:analytica/analyzer.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart' hide WildcardPattern;
import 'package:analyzer/dart/element/element.dart';
import 'package:path/path.dart' as p;

import 'comment_parser.dart';
import 'models.dart';
import 'reachability_engine_helpers.dart';
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
    final (crossLibraryReferenced, testReferencedIds) = connectReferenceEdges(
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
    final productionLive = runBfs(
      startIds: productionRoots,
      idToNode: data.idToNode,
      sealedSubtypes: data.sealedSubtypes,
    );

    final testReachable = runBfs(
      startIds: testRoots,
      idToNode: data.idToNode,
      sealedSubtypes: data.sealedSubtypes,
    );

    // Step 4.5: Identify active test-support roots and compute testSupportLive.
    final activeTestSupportRoots = data.allNodes
        .where(
          (n) =>
              testReachable.contains(n.id) &&
              (n.isTestSupport ||
                  WildcardPattern.anyMatch(_testSupportWildcards, n.name)),
        )
        .map((n) => n.id)
        .toSet();

    final testSupportLive = runBfs(
      startIds: activeTestSupportRoots,
      idToNode: data.idToNode,
      sealedSubtypes: data.sealedSubtypes,
    );

    // Step 5: Candidate Classification and Hazard Detection.
    final classification = _classifyFindings(
      allNodes: data.allNodes,
      topology: topology,
      productionLive: productionLive,
      testReachable: testReachable,
      testSupportLive: testSupportLive,
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

    findings.sort(compareFindings);

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
    collectExistingPaths(options.extraRoots, absolutePackagePath, extraPaths);
    collectExistingPaths(
      topology.extraProductionFiles,
      absolutePackagePath,
      extraPaths,
    );
    collectExistingPaths(
      topology.extraTestFiles,
      absolutePackagePath,
      extraPaths,
    );
    return AnalysisContextHelper(
      includedPaths: [absolutePackagePath, ...extraPaths],
      sdkPath: options.sdkPath,
    );
  }

  Future<HarvestedData> _harvestDeclarationsAndTestSites({
    required AnalysisContextHelper contextHelper,
    required PackageTopology topology,
    required String absolutePackagePath,
  }) async {
    final data = HarvestedData();
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
    required HarvestedData data,
  }) {
    final isFileIgnored = CommentParser.hasIgnoreForFile(unitResult.unit);
    final role = topology.roleOf(relPath);

    collectConditionalImports(
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
    required HarvestedData data,
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
      indexVariableElement(
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

  void _registerNonVariableDeclaration({
    required Declaration decl,
    required ResolvedUnitResult unitResult,
    required String relPath,
    required String absPath,
    required String absolutePackagePath,
    required bool isFileIgnored,
    required ElementReferenceExtractor fileDirectivesExtractor,
    required HarvestedData data,
  }) {
    data.totalDeclarationsCount++;
    final name = extractNodeName(decl) ?? 'anonymous';
    final (kind, isSealed) = classifyDeclaration(decl);
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

    final superElements = extractSuperElements(element);

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

  void _extractTestSites(
    ResolvedUnitResult unitResult,
    String relPath,
    String absolutePackagePath,
    HarvestedData data,
  ) {
    final visitor = TestCallSiteVisitor(
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

  Future<(Set<String>, Set<String>, Set<String>)> _identifyRoots({
    required AnalysisContextHelper contextHelper,
    required PackageTopology topology,
    required String absolutePackagePath,
    required HarvestedData data,
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
    required HarvestedData data,
    required Set<String> productionRoots,
    required Set<String> exportedNodeIds,
    required Set<String> crossLibraryReferenced,
  }) async {
    if (options.mode != AnalysisMode.library) return;

    for (final relPath in topology.publicLibFiles) {
      final absPath = p.join(absolutePackagePath, relPath);
      final unitResult = await contextHelper.getResolvedUnit(absPath);
      if (unitResult is ResolvedUnitResult) {
        harvestExportedNamespace(
          unitResult.libraryElement,
          data,
          productionRoots,
          exportedNodeIds,
          crossLibraryReferenced,
        );
      }

      addPublicNodesForFile(
        relPath,
        data.allNodes,
        productionRoots,
        exportedNodeIds,
        crossLibraryReferenced,
      );

      harvestConditionalPublicTargets(
        relPath,
        data,
        productionRoots,
        exportedNodeIds,
        crossLibraryReferenced,
      );
    }
  }

  void _harvestNonLibraryRoots({
    required List<DeclarationNode> allNodes,
    required PackageTopology topology,
    required Set<String> productionRoots,
    required Set<String> testRoots,
  }) {
    for (final node in allNodes) {
      if (isTestRoot(node, topology)) {
        testRoots.add(node.id);
      }
      if (isExecutableRoot(node, topology) ||
          _isDemonstrationRoot(node, topology) ||
          isAuxiliaryRoot(node, topology) ||
          isConfigOrNativeRoot(node, topology) ||
          isExtraProductionRoot(node, topology)) {
        productionRoots.add(node.id);
      }
    }
  }

  bool _isDemonstrationRoot(DeclarationNode node, PackageTopology topology) {
    if (topology.roleOf(node.relativeFilePath) != FileRole.demonstration) {
      return false;
    }
    if (options.exampleMode == ExampleMode.demonstration) return true;
    if (options.exampleMode == ExampleMode.strict) return node.name == 'main';
    return false;
  }

  ClassificationResult _classifyFindings({
    required List<DeclarationNode> allNodes,
    required PackageTopology topology,
    required Set<String> productionLive,
    required Set<String> testReachable,
    required Set<String> testSupportLive,
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
        findings.add(createPureUndeadFinding(node));
      } else {
        final (finding, isHazard) = _classifyTestedNode(
          node,
          testSites: testSites,
          productionLive: productionLive,
          testSupportLive: testSupportLive,
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

    return ClassificationResult(
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
    if (isDirectSubtypeOfLiveSealed(
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

  (UndeadFinding?, bool isHazard) _classifyTestedNode(
    DeclarationNode node, {
    required List<TestBlockSite> testSites,
    required Set<String> productionLive,
    required Set<String> testSupportLive,
  }) {
    if (testSupportLive.contains(node.id)) return (null, false);

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
