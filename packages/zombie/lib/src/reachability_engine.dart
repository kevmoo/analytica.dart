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
class ZombieEngine {
  final ZombieOptions options;
  final List<WildcardPattern> _ignoreNameWildcards;
  final List<WildcardPattern> _testSupportWildcards;

  ZombieEngine(this.options)
    : _ignoreNameWildcards = options.ignoreNamePatterns
          .map(WildcardPattern.new)
          .toList(),
      _testSupportWildcards = options.testSupportPatterns
          .map(WildcardPattern.new)
          .toList();

  /// Performs reachability analysis on the target package.
  Future<ZombieReport> analyze() async {
    final harvester = RootHarvester(options);
    final topology = harvester.harvestTopology();

    final absolutePackagePath = p.normalize(p.absolute(options.packagePath));
    final extraRootPaths = options.extraRoots
        .map(
          (r) =>
              p.normalize(p.isAbsolute(r) ? r : p.join(absolutePackagePath, r)),
        )
        .where((path) => Directory(path).existsSync())
        .toList();
    final contextHelper = AnalysisContextHelper(
      includedPaths: [absolutePackagePath, ...extraRootPaths],
      sdkPath: options.sdkPath,
    );

    final allNodes = <DeclarationNode>[];
    final elementToNode = <Element, DeclarationNode>{};
    final locationToNode = <String, DeclarationNode>{};
    final idToNode = <String, DeclarationNode>{};
    final testSites = <TestBlockSite>[];
    final testSiteRawElements = <TestBlockSite, Set<Element>>{};
    final nodeOutboundElements = <DeclarationNode, Set<Element>>{};
    final nodeDirectSuperElements = <DeclarationNode, List<Element>>{};
    final sealedSubtypes = <String, Set<String>>{};
    final conditionalTargets = <String, Set<String>>{};

    var totalDeclarationsCount = 0;

    // Step 1: Single-pass parse and resolution for all files in topology.
    for (final relPath in topology.allFiles) {
      final absPath = p.normalize(
        p.isAbsolute(relPath) ? relPath : p.join(absolutePackagePath, relPath),
      );
      final unitResult = await contextHelper.getResolvedUnit(absPath);

      if (unitResult == null) {
        continue;
      }

      final isFileIgnored = CommentParser.hasIgnoreForFile(unitResult.unit);
      final role = topology.roleOf(relPath);

      // Collect conditional imports in directives.
      for (final directive in unitResult.unit.directives) {
        if (directive is NamespaceDirective &&
            directive.configurations.isNotEmpty) {
          final targets = <String>{};
          final defaultUri = directive.uri.stringValue;
          if (defaultUri != null && defaultUri.isNotEmpty) {
            final resolvedTarget = _resolveUri(
              relPath,
              defaultUri,
              topology.packageName,
            );
            if (resolvedTarget != null) {
              targets.add(resolvedTarget);
            }
          }
          for (final config in directive.configurations) {
            final uriStr = config.uri.stringValue;
            if (uriStr != null && uriStr.isNotEmpty) {
              final resolvedTarget = _resolveUri(
                relPath,
                uriStr,
                topology.packageName,
              );
              if (resolvedTarget != null) {
                targets.add(resolvedTarget);
              }
            }
          }
          if (targets.isNotEmpty) {
            final allGroupFiles = {relPath, ...targets};
            for (final file in allGroupFiles) {
              conditionalTargets
                  .putIfAbsent(file, () => {})
                  .addAll(allGroupFiles.where((f) => f != file));
            }
          }
        }
      }

      // Collect file-level export directive references.
      final fileDirectivesExtractor = ElementReferenceExtractor(
        absolutePackagePath,
      );
      for (final directive in unitResult.unit.directives) {
        if (directive is ExportDirective) {
          directive.accept(fileDirectivesExtractor);
        }
      }

      // Collect top-level declarations.
      for (final decl in unitResult.unit.declarations) {
        final isDeclIgnored =
            isFileIgnored || CommentParser.isDeclarationIgnored(decl);

        if (decl is TopLevelVariableDeclaration) {
          final isExternalJsInterop = options.frameworkAdapter
              .isExternalJsInterop(decl, null);
          final isNativeRoot =
              isNativeOrEntryPoint(decl) ||
              options.frameworkAdapter.isFrameworkEntryPoint(decl, null);
          for (final variable in decl.variables.variables) {
            totalDeclarationsCount++;
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
              isExternalJsInterop:
                  isExternalJsInterop ||
                  options.frameworkAdapter.isExternalJsInterop(decl, element),
              isNativeRoot:
                  isNativeRoot ||
                  options.frameworkAdapter.isFrameworkEntryPoint(decl, element),
            );

            allNodes.add(node);
            idToNode[id] = node;
            locationToNode['${p.canonicalize(absPath)}#$name'] = node;
            if (element != null) {
              elementToNode[element] = node;
              if (element is TopLevelVariableElement) {
                final getter = element.getter;
                if (getter != null) {
                  elementToNode[getter] = node;
                  final getterKey = '${p.canonicalize(absPath)}#${getter.name}';
                  locationToNode[getterKey] = node;
                }
                final setter = element.setter;
                if (setter != null) {
                  elementToNode[setter] = node;
                  final setterKey = '${p.canonicalize(absPath)}#${setter.name}';
                  locationToNode[setterKey] = node;
                }
              }
            }

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
            nodeOutboundElements[node] = extractor.referencedTopLevelElements;
          }
        } else {
          totalDeclarationsCount++;
          final name = extractNodeName(decl) ?? 'anonymous';
          final (kind, isSealed) = _classifyDeclaration(decl);
          final id = '$relPath#${kind.jsonValue}#$name#${decl.offset}';
          final lineInfo = unitResult.lineInfo.getLocation(decl.offset);
          final element = decl.declaredFragment?.element;
          final isTestSupport = isTestSupportDeclaration(decl, name);
          final isExternalJsInterop = options.frameworkAdapter
              .isExternalJsInterop(decl, element);
          final isNativeRoot =
              isNativeOrEntryPoint(decl) ||
              options.frameworkAdapter.isFrameworkEntryPoint(decl, element);

          final superElements = <Element>[];
          if (element is InterfaceElement) {
            final supertype = element.supertype;
            if (supertype != null) superElements.add(supertype.element);
            for (final iface in element.interfaces) {
              superElements.add(iface.element);
            }
            for (final mixinType in element.mixins) {
              superElements.add(mixinType.element);
            }
          }

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
            isExternalJsInterop: isExternalJsInterop,
            isNativeRoot: isNativeRoot,
          );

          allNodes.add(node);
          idToNode[id] = node;
          locationToNode['${p.canonicalize(absPath)}#$name'] = node;
          if (element != null) {
            elementToNode[element] = node;
          }
          if (superElements.isNotEmpty) {
            nodeDirectSuperElements[node] = superElements;
          }

          final extractor = ElementReferenceExtractor(absolutePackagePath);
          decl.accept(extractor);
          if (fileDirectivesExtractor.referencedTopLevelElements.isNotEmpty) {
            extractor.referencedTopLevelElements.addAll(
              fileDirectivesExtractor.referencedTopLevelElements,
            );
          }
          nodeOutboundElements[node] = extractor.referencedTopLevelElements;
        }
      }

      // If test file, extract test block sites.
      if (role == FileRole.test) {
        final visitor = _TestCallSiteVisitor(
          packageRoot: absolutePackagePath,
          relativeFilePath: relPath,
          lineInfo: unitResult.lineInfo,
          frameworkAdapter: options.frameworkAdapter,
        );
        unitResult.unit.accept(visitor);
        for (final entry in visitor.discoveredSites) {
          testSites.add(entry.site);
          testSiteRawElements[entry.site] = entry.referencedElements;
        }
      }
    }

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

    // Step 2: Connect reference edges and sealed hierarchies.
    for (final node in allNodes) {
      final outbound = nodeOutboundElements[node];
      if (outbound != null) {
        for (final refElem in outbound) {
          final targetNode = resolveNodeForElement(refElem);
          if (targetNode != null && targetNode.id != node.id) {
            node.outgoingTargetIds.add(targetNode.id);
          }
        }
      }

      final superElems = nodeDirectSuperElements[node];
      if (superElems != null) {
        for (final superElem in superElems) {
          final parentNode = resolveNodeForElement(superElem);
          if (parentNode != null && parentNode.isSealed) {
            sealedSubtypes.putIfAbsent(parentNode.id, () => {}).add(node.id);
          }
        }
      }
    }

    // Connect conditional import reachability edges from importing files.
    for (final entry in conditionalTargets.entries) {
      final sourceRelPath = entry.key;
      final targetRelPaths = entry.value;
      final sourceNodes = allNodes
          .where((n) => n.relativeFilePath == sourceRelPath)
          .toList();
      final targetNodes = allNodes
          .where((n) => targetRelPaths.contains(n.relativeFilePath))
          .toList();
      for (final sourceNode in sourceNodes) {
        for (final targetNode in targetNodes) {
          sourceNode.outgoingTargetIds.add(targetNode.id);
        }
      }
    }

    for (final site in testSites) {
      final rawElems = testSiteRawElements[site];
      if (rawElems != null) {
        for (final elem in rawElems) {
          final targetNode = resolveNodeForElement(elem);
          if (targetNode != null) {
            site.referencedDeclarationIds.add(targetNode.id);
          }
        }
      }
    }

    // Step 3: Identify roots for Production and Tests.
    final productionRoots = <String>{};
    final testRoots = <String>{};

    // 3.1 Public API roots (Open-World Invariant under library mode).
    if (options.mode == AnalysisMode.library) {
      for (final relPath in topology.publicLibFiles) {
        final absPath = p.join(absolutePackagePath, relPath);
        final unitResult = await contextHelper.getResolvedUnit(absPath);
        if (unitResult is ResolvedUnitResult) {
          final libElem = unitResult.libraryElement;
          for (final exportedElem
              in libElem.exportNamespace.definedNames2.values) {
            final topLevel = getTopLevelElement(exportedElem);
            if (topLevel != null) {
              final node = elementToNode[topLevel];
              if (node != null) {
                productionRoots.add(node.id);
              }
            }
          }
        }

        // Also add non-private top-level declarations in public files as roots.
        for (final node in allNodes) {
          if (node.relativeFilePath == relPath && !node.name.startsWith('_')) {
            productionRoots.add(node.id);
          }
        }

        // Activate conditional import targets of public library files.
        final targets = conditionalTargets[relPath];
        if (targets != null) {
          for (final targetRelPath in targets) {
            for (final node in allNodes) {
              if (node.relativeFilePath == targetRelPath &&
                  !node.name.startsWith('_')) {
                productionRoots.add(node.id);
              }
            }
          }
        }
      }
    }

    // 3.2 Executable roots (bin/** main, lib/main.dart & lib/main_*.dart main).
    for (final node in allNodes) {
      final isBinMain =
          topology.roleOf(node.relativeFilePath) == FileRole.executable &&
          node.name == 'main';
      final isFlutterMain =
          PackageTopology.isFlutterEntrypoint(node.relativeFilePath) &&
          node.name == 'main' &&
          topology.frameworkRoots.contains('main');
      if (isBinMain || isFlutterMain) {
        productionRoots.add(node.id);
      }
    }

    // 3.3 Demonstration roots (example/**).
    if (options.exampleMode == ExampleMode.demonstration) {
      for (final node in allNodes) {
        if (topology.roleOf(node.relativeFilePath) == FileRole.demonstration) {
          productionRoots.add(node.id);
        }
      }
    } else if (options.exampleMode == ExampleMode.strict) {
      for (final node in allNodes) {
        if (topology.roleOf(node.relativeFilePath) == FileRole.demonstration &&
            node.name == 'main') {
          productionRoots.add(node.id);
        }
      }
    }

    // 3.4 Auxiliary roots (tool/**, benchmark/**, web/** main).
    for (final node in allNodes) {
      if (topology.roleOf(node.relativeFilePath) == FileRole.auxiliary &&
          node.name == 'main') {
        productionRoots.add(node.id);
      }
    }

    // 3.5 Config and native roots (build.yaml, pubspec plugins, @Native,
    // @pragma, framework roots).
    for (final node in allNodes) {
      if (node.isNativeRoot) {
        productionRoots.add(node.id);
      } else if (topology.frameworkRoots.contains(node.name)) {
        if (node.name != 'main' ||
            PackageTopology.isFlutterEntrypoint(node.relativeFilePath)) {
          productionRoots.add(node.id);
        }
      }
    }

    // 3.6 Test roots (test/** declarations).
    for (final node in allNodes) {
      if (topology.roleOf(node.relativeFilePath) == FileRole.test) {
        testRoots.add(node.id);
      }
    }

    // Step 4: Dual-Pass BFS Graph Traversal.
    final productionLive = _runBfs(
      startIds: productionRoots,
      idToNode: idToNode,
      sealedSubtypes: sealedSubtypes,
    );

    final testReachable = _runBfs(
      startIds: testRoots,
      idToNode: idToNode,
      sealedSubtypes: sealedSubtypes,
    );

    // Step 5: Candidate Classification and Hazard Detection.
    final findings = <ZombieFinding>[];
    var pureZombies = 0;
    var testedZombies = 0;
    var coInvokedHazards = 0;

    for (final node in allNodes) {
      final role = topology.roleOf(node.relativeFilePath);

      // Check if this node is in an analysis candidate scope.
      final isCandidate = switch (role) {
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

      if (!isCandidate) continue;
      if (node.isIgnored) continue;
      if (options.ignoreExternalInterop && node.isExternalJsInterop) continue;
      if (WildcardPattern.anyMatch(_ignoreNameWildcards, node.name)) continue;
      if (productionLive.contains(node.id)) continue;

      // Sealed class direct subtype preservation:
      final superElems = nodeDirectSuperElements[node];
      var isDirectSubtypeOfLiveSealed = false;
      if (superElems != null) {
        for (final superElem in superElems) {
          final parentNode = elementToNode[superElem];
          if (parentNode != null &&
              parentNode.isSealed &&
              productionLive.contains(parentNode.id)) {
            isDirectSubtypeOfLiveSealed = true;
            break;
          }
        }
      }
      if (isDirectSubtypeOfLiveSealed) {
        // Direct subtype of live sealed class: preserved for exhaustiveness!
        continue;
      }

      if (!testReachable.contains(node.id)) {
        // Pure Zombie
        pureZombies++;
        findings.add(
          ZombieFinding(
            id: node.name,
            name: node.name,
            kind: node.kind,
            file: node.relativeFilePath,
            line: node.line,
            column: node.column,
            length: node.length,
            classification: ZombieClassification.pureZombie,
            suggestedAction: SuggestedAction.delete,
            isExternalJsInterop: node.isExternalJsInterop,
          ),
        );
      } else {
        // Reached by tests.
        final isTestHook =
            node.isTestSupport ||
            WildcardPattern.anyMatch(_testSupportWildcards, node.name);
        if (isTestHook) {
          // Explicit test fixture/hook (@visibleForTesting, Fake*): preserved!
          continue;
        }

        // Evaluate orphan test sites and co-invoked hazards.
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

        if (hasCoInvokedHazard) {
          coInvokedHazards++;
          findings.add(
            ZombieFinding(
              id: node.name,
              name: node.name,
              kind: node.kind,
              file: node.relativeFilePath,
              line: node.line,
              column: node.column,
              length: node.length,
              classification: ZombieClassification.coInvokedHazard,
              suggestedAction: SuggestedAction.manualRefactorHazard,
              orphanTests: orphanSites.isNotEmpty ? orphanSites : null,
              isExternalJsInterop: node.isExternalJsInterop,
            ),
          );
        } else {
          testedZombies++;
          findings.add(
            ZombieFinding(
              id: node.name,
              name: node.name,
              kind: node.kind,
              file: node.relativeFilePath,
              line: node.line,
              column: node.column,
              length: node.length,
              classification: ZombieClassification.testedZombie,
              suggestedAction: SuggestedAction.deleteWithOrphanTests,
              orphanTests: orphanSites.isNotEmpty ? orphanSites : null,
              isExternalJsInterop: node.isExternalJsInterop,
            ),
          );
        }
      }
    }

    findings.sort((a, b) {
      final fileComp = a.file.compareTo(b.file);
      if (fileComp != 0) return fileComp;
      final lineComp = a.line.compareTo(b.line);
      if (lineComp != 0) return lineComp;
      return a.column.compareTo(b.column);
    });

    return ZombieReport(
      version: '0.1.0',
      package: topology.packageName,
      totalDeclarations: totalDeclarationsCount,
      pureZombiesFound: pureZombies,
      testedZombiesFound: testedZombies,
      coInvokedHazardsFound: coInvokedHazards,
      zombies: findings,
    );
  }

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

      // If this is a sealed class, also traverse all its direct subtypes.
      if (node.isSealed) {
        final subtypes = sealedSubtypes[currentId];
        if (subtypes != null) {
          for (final subId in subtypes) {
            if (visited.add(subId)) {
              queue.add(subId);
            }
          }
        }
      }
    }

    return visited;
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
Future<ZombieReport> analyzePackage(
  String packagePath, {
  ZombieOptions? options,
}) async {
  final opts = options ?? ZombieOptions(packagePath: packagePath);
  final engine = ZombieEngine(opts);
  return engine.analyze();
}
