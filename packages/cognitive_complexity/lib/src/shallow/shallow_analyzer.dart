import 'dart:io';

import 'package:analytica/analyzer.dart';
import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:path/path.dart' as p;

import '../complexity/cognitive_complexity_visitor.dart';
import 'ast_collector.dart';
import 'models.dart';

/// Analyzes Dart files and directories to detect single-caller shallow helper
/// functions and simulate their exact caller Cognitive Complexity when inlined.
class ShallowAnalyzer {
  final PathFilter pathFilter;
  final int maxCallerScore;
  final int maxParams;
  final FeatureSet _featureSet = FeatureSet.latestLanguageVersion();

  ShallowAnalyzer({
    PathFilter? pathFilter,
    this.maxCallerScore = 15,
    this.maxParams = 5,
  }) : pathFilter = pathFilter ?? PathFilter.defaults;

  /// Analyzes a single file or directory at [targetPath].
  ShallowReport analyzePath(String targetPath) => analyzePaths([targetPath]);

  /// Analyzes multiple files or directories at [targetPaths].
  ///
  /// When [modifiedFilesFilter] is provided (e.g. from `--git-diff`), only
  /// declarations inside those normalized relative file paths are reported,
  /// while call sites are still resolved across the enclosing package.
  ShallowReport analyzePaths(
    List<String> targetPaths, {
    Set<String>? modifiedFilesFilter,
  }) {
    final fileEntries = _discoverScanFiles(targetPaths, modifiedFilesFilter);
    final parsedUnits = <({_ScanFileEntry entry, ParseStringResult parsed})>[];
    final conditionalFiles = <String>{};
    final exportTracker = ExportedSurfaceTracker();

    for (final entry in fileEntries) {
      final ParseStringResult parsed;
      try {
        parsed = parseFile(
          path: entry.absPath,
          featureSet: _featureSet,
          throwIfDiagnostics: false,
        );
      } catch (_) {
        continue;
      }
      parsedUnits.add((entry: entry, parsed: parsed));
      collectConditionalDirectiveFiles(
        directives: parsed.unit.directives,
        filePath: entry.normalizedPath,
        conditionalFiles: conditionalFiles,
      );
      if (entry.isPublicEntryFile) {
        exportTracker.recordExportDirectives(
          directives: parsed.unit.directives,
          filePath: entry.normalizedPath,
        );
      }
    }

    return _evaluateParsedUnits(
      parsedUnits: parsedUnits,
      conditionalFiles: conditionalFiles,
      exportTracker: exportTracker,
    );
  }

  /// Analyzes in-memory Dart source [code] directly for unit testing.
  ShallowReport analyzeCode(String code, {String filePath = '<memory>'}) {
    final parsed = parseString(
      content: code,
      featureSet: _featureSet,
      throwIfDiagnostics: false,
    );
    if (shallowDirectiveParser.hasIgnoreForFile(parsed.unit)) {
      return ShallowReport(
        findings: const [],
        declarationsScanned: 0,
        maxCallerScore: maxCallerScore,
        maxParams: maxParams,
      );
    }

    final normPath = p.normalize(filePath);
    final conditionalFiles = <String>{};
    final exportTracker = ExportedSurfaceTracker();
    collectConditionalDirectiveFiles(
      directives: parsed.unit.directives,
      filePath: filePath,
      conditionalFiles: conditionalFiles,
    );

    final entry = _ScanFileEntry(
      absPath: filePath,
      displayPath: filePath,
      normalizedPath: normPath,
      isTestFile: false,
      isPublicEntryFile: false,
      isInRequestedTargets: true,
    );
    return _evaluateParsedUnits(
      parsedUnits: [(entry: entry, parsed: parsed)],
      conditionalFiles: conditionalFiles,
      exportTracker: exportTracker,
    );
  }

  ShallowReport _evaluateParsedUnits({
    required List<({_ScanFileEntry entry, ParseStringResult parsed})>
    parsedUnits,
    required Set<String> conditionalFiles,
    required ExportedSurfaceTracker exportTracker,
  }) {
    final allDecls = <ShallowDeclNode>[];
    final callsByName = <String, List<ShallowCallSite>>{};
    final fieldsByFile = <String, Map<String, Set<String>>>{};

    for (final (:entry, :parsed) in parsedUnits) {
      if (shallowDirectiveParser.hasIgnoreForFile(parsed.unit)) continue;
      final collector = ShallowFileCollector(
        filePath: entry.displayPath,
        normalizedFilePath: entry.normalizedPath,
        lineInfo: parsed.lineInfo,
        isTestFile: entry.isTestFile,
        isPublicEntryFile: entry.isPublicEntryFile,
        isConditionalFile: conditionalFiles.contains(entry.normalizedPath),
        isInRequestedTargets: entry.isInRequestedTargets,
        exportTracker: exportTracker,
      );
      parsed.unit.accept(collector);
      if (!entry.isTestFile) {
        allDecls.addAll(collector.declarations);
        fieldsByFile[entry.normalizedPath] = collector.fieldNamesByType;
      }
      for (final call in collector.calls) {
        callsByName.putIfAbsent(call.calleeName, () => []).add(call);
      }
    }

    final declsByName = <String, List<ShallowDeclNode>>{};
    final declsByFile = <String, List<ShallowDeclNode>>{};
    for (final d in allDecls) {
      declsByName.putIfAbsent(d.rawName, () => []).add(d);
      declsByFile.putIfAbsent(d.normalizedFilePath, () => []).add(d);
    }

    final rawCandidates = <_RawCandidate>[];
    var scannedCount = 0;
    for (final decl in allDecls) {
      if (!decl.isInRequestedTargets) continue;
      scannedCount++;
      final candidate = _evaluateCandidate(
        decl: decl,
        callsByName: callsByName,
        declsByName: declsByName,
        sameFileDecls: declsByFile[decl.normalizedFilePath] ?? const [],
        sameFileFields: fieldsByFile[decl.normalizedFilePath] ?? const {},
      );
      if (candidate != null) rawCandidates.add(candidate);
    }

    final findings = _resolveCumulativeCandidates(rawCandidates);
    findings.sort(_buildFindingComparator(findings));
    return ShallowReport(
      findings: findings,
      declarationsScanned: scannedCount,
      maxCallerScore: maxCallerScore,
      maxParams: maxParams,
    );
  }

  _RawCandidate? _evaluateCandidate({
    required ShallowDeclNode decl,
    required Map<String, List<ShallowCallSite>> callsByName,
    required Map<String, List<ShallowDeclNode>> declsByName,
    required List<ShallowDeclNode> sameFileDecls,
    required Map<String, Set<String>> sameFileFields,
  }) {
    if (decl.isExempt) return null;

    final allCalls = callsByName[decl.rawName] ?? const [];
    final sameNameDecls = declsByName[decl.rawName] ?? const [];
    final matchingCalls = decl.isPrivate
        ? allCalls
              .where(
                (c) =>
                    !c.isTestFile &&
                    (sameNameDecls.length == 1 ||
                        c.normalizedFilePath == decl.normalizedFilePath),
              )
              .toList()
        : allCalls;

    final prodCalls = matchingCalls.where((c) => !c.isTestFile).toList();
    final testCalls = matchingCalls.where((c) => c.isTestFile).toList();
    if (prodCalls.length != 1 ||
        testCalls.isNotEmpty ||
        matchingCalls.any((c) => c.isTearOff)) {
      return null;
    }

    final call = prodCalls.single;
    final caller = call.caller;
    if (caller == null || identical(caller, decl)) return null;
    if (_isExemptCallerOrCrossFileFacade(decl, caller)) return null;

    final reasons = _computeShallowReasons(decl, caller);
    if (reasons.isEmpty) return null;

    final baseDeltaScore = scoreAstParts(
      decl.ccParts,
      initialDepth: call.nestingDepth,
    );
    final estLinesSaved =
        decl.signatureLines +
        (decl.parameterCount >= 3 ? decl.parameterCount + 1 : 2);
    final facts = _computeParameterFacts(decl, sameFileDecls, sameFileFields);

    return _RawCandidate(
      decl: decl,
      caller: caller,
      call: call,
      baseDeltaScore: baseDeltaScore,
      estimatedLinesSaved: estLinesSaved,
      reasons: reasons,
      sharedParamSignatureWith: facts.sharedWith,
      sharedParamCount: facts.sharedCount,
      paramsSubsetOfExistingType: facts.subsetOf,
    );
  }

  bool _isExemptCallerOrCrossFileFacade(
    ShallowDeclNode decl,
    ShallowDeclNode caller,
  ) {
    if (caller.rawName == 'main' &&
        p.split(caller.normalizedFilePath).contains('bin')) {
      return true;
    }
    final enclosingType = decl.enclosingType;
    if (enclosingType != null &&
        !enclosingType.startsWith('_') &&
        !decl.isPrivate &&
        caller.enclosingType != enclosingType) {
      return true;
    }
    return caller.normalizedFilePath != decl.normalizedFilePath &&
        decl.referencedPrivateNames.isNotEmpty;
  }

  List<ShallowFinding> _resolveCumulativeCandidates(
    List<_RawCandidate> rawCandidates,
  ) {
    final prioritized = List<_RawCandidate>.from(rawCandidates)
      ..sort(_compareRawCandidates);
    final ordered = _orderBottomUp(prioritized);
    final effectiveScore = <ShallowDeclNode, int>{};
    final absorbedChildren =
        <ShallowDeclNode, List<({ShallowDeclNode decl, int relativeDepth})>>{};
    final findings = <ShallowFinding>[];

    for (final (index, c) in ordered.indexed) {
      final children = absorbedChildren[c.decl] ?? const [];
      var deltaScore = c.baseDeltaScore;
      for (final sub in children) {
        deltaScore += scoreAstParts(
          sub.decl.ccParts,
          initialDepth: c.call.nestingDepth + sub.relativeDepth,
        );
      }
      final callerScore = effectiveScore[c.caller] ?? c.caller.score;
      final inlinedCallerScore = callerScore + deltaScore;
      final classification = _classifyInlinedScore(
        inlinedCallerScore: inlinedCallerScore,
        helperScore: c.decl.score,
        callNestingDepth: c.call.nestingDepth,
        hasAbsorbedChildren: children.isNotEmpty,
      );
      if (classification == ShallowClassification.safeInline) {
        effectiveScore[c.caller] = inlinedCallerScore;
        final callerAbsorbed = absorbedChildren.putIfAbsent(
          c.caller,
          () => <({ShallowDeclNode decl, int relativeDepth})>[],
        )..add((decl: c.decl, relativeDepth: c.call.nestingDepth));
        for (final sub in children) {
          callerAbsorbed.add((
            decl: sub.decl,
            relativeDepth: c.call.nestingDepth + sub.relativeDepth,
          ));
        }
      }
      findings.add(
        ShallowFinding(
          filePath: c.decl.filePath,
          name: c.decl.qualifiedName,
          startLine: c.decl.startLine,
          endLine: c.decl.endLine,
          parameterCount: c.decl.parameterCount,
          namedParameterCount: c.decl.namedParameterCount,
          effectiveParameterCount: c.decl.effectiveParameterCount,
          signatureLines: c.decl.signatureLines,
          bodyLines: c.decl.bodyLines,
          statementCount: c.decl.statementCount,
          score: c.decl.score,
          callerFilePath: c.call.filePath,
          callerName: c.caller.qualifiedName,
          callerZone: _zoneOf(c.caller.normalizedFilePath),
          callLine: c.call.line,
          callNestingDepth: c.call.nestingDepth,
          callerBaseScore: c.caller.score,
          callerCumulativeBefore: callerScore,
          inlinedDeltaScore: deltaScore,
          inlinedCallerScore: inlinedCallerScore,
          inlinedCallerScoreIsolated: c.caller.score + deltaScore,
          headroomAfterInline: maxCallerScore - inlinedCallerScore,
          sharedParamSignatureWith: c.sharedParamSignatureWith,
          sharedParamCount: c.sharedParamCount,
          paramsSubsetOfExistingType: c.paramsSubsetOfExistingType,
          simulationIndex: index,
          estimatedLinesSaved: c.estimatedLinesSaved,
          classification: classification,
          reasons: c.reasons,
        ),
      );
    }
    return findings;
  }

  /// Same-file parameter facts that point at a remedy other than inlining:
  /// a sibling declaration sharing `>= 4` parameter names (prefer a shared
  /// parameter record) or a type whose instance fields cover `>= 4` of the
  /// parameters (pass that object directly).
  static ({String? sharedWith, int sharedCount, String? subsetOf})
  _computeParameterFacts(
    ShallowDeclNode decl,
    List<ShallowDeclNode> sameFileDecls,
    Map<String, Set<String>> sameFileFields,
  ) {
    final names = decl.parameterNames.map(_stripUnderscore).toSet();
    if (names.length < _minSharedParams) {
      return (sharedWith: null, sharedCount: 0, subsetOf: null);
    }
    final (:sharedWith, :sharedCount) = _sharedSignature(
      decl,
      names,
      sameFileDecls,
    );
    return (
      sharedWith: sharedWith,
      sharedCount: sharedCount,
      subsetOf: _fieldSubsetType(decl, names, sameFileFields),
    );
  }

  static const _minSharedParams = 4;

  /// Sibling declaration sharing the most parameter names with [names]
  /// (`null`/0 when below [_minSharedParams]).
  static ({String? sharedWith, int sharedCount}) _sharedSignature(
    ShallowDeclNode decl,
    Set<String> names,
    List<ShallowDeclNode> sameFileDecls,
  ) {
    String? sharedWith;
    var sharedCount = 0;
    for (final sibling in sameFileDecls) {
      if (identical(sibling, decl)) continue;
      final shared = sibling.parameterNames
          .map(_stripUnderscore)
          .where(names.contains)
          .length;
      if (shared > sharedCount) {
        sharedCount = shared;
        sharedWith = sibling.qualifiedName;
      }
    }
    if (sharedCount < _minSharedParams) {
      return (sharedWith: null, sharedCount: 0);
    }
    return (sharedWith: sharedWith, sharedCount: sharedCount);
  }

  /// Same-file type whose instance fields cover `>= _minSharedParams` of
  /// [names]; the enclosing type wins whenever it qualifies.
  static String? _fieldSubsetType(
    ShallowDeclNode decl,
    Set<String> names,
    Map<String, Set<String>> sameFileFields,
  ) {
    String? subsetOf;
    var subsetCount = 0;
    for (final MapEntry(key: type, value: fields) in sameFileFields.entries) {
      final covered = fields.map(_stripUnderscore).where(names.contains).length;
      final preferred =
          type == decl.enclosingType && covered >= _minSharedParams;
      if (covered > subsetCount || preferred) {
        subsetCount = covered;
        subsetOf = type;
        if (preferred) break;
      }
    }
    return subsetCount < _minSharedParams ? null : subsetOf;
  }

  static String _stripUnderscore(String name) =>
      name.startsWith('_') ? name.substring(1) : name;

  ShallowClassification _classifyInlinedScore({
    required int inlinedCallerScore,
    required int helperScore,
    required int callNestingDepth,
    required bool hasAbsorbedChildren,
  }) {
    if (inlinedCallerScore < maxCallerScore) {
      return ShallowClassification.safeInline;
    }
    if (inlinedCallerScore == maxCallerScore) {
      return ShallowClassification.zeroHeadroom;
    }
    if (helperScore <= 4 &&
        callNestingDepth > 0 &&
        inlinedCallerScore <= maxCallerScore + 7 &&
        !hasAbsorbedChildren) {
      return ShallowClassification.flattenAndInline;
    }
    return ShallowClassification.loadBearing;
  }

  List<String> _computeShallowReasons(
    ShallowDeclNode decl,
    ShallowDeclNode caller,
  ) {
    final reasons = <String>[];
    if (decl.effectiveParameterCount >= maxParams) {
      final effective = decl.effectiveParameterCount != decl.parameterCount
          ? ', ${decl.effectiveParameterCount} effective'
          : '';
      reasons.add('HIGH_ARITY(${decl.parameterCount} params$effective)');
    }
    final isTiny =
        decl.bodyLines <= 6 ||
        (decl.statementCount <= 2 && decl.bodyLines <= 15);
    if (isTiny && decl.score <= 2) {
      reasons.add(
        'MICRO_HELPER(${decl.bodyLines} bodyL, ${decl.statementCount} stmt, '
        'CC=${decl.score})',
      );
    }
    if (decl.parameterCount >= 3 && decl.signatureLines >= decl.bodyLines - 2) {
      reasons.add(
        'SIG_HEAVY(sig=${decl.signatureLines}L vs body=${decl.bodyLines}L)',
      );
    }
    final isStandaloneHelper = decl.enclosingType == null || decl.isStatic;
    if (isStandaloneHelper &&
        caller.normalizedFilePath != decl.normalizedFilePath &&
        !_isLibraryToConsumerEdge(decl, caller) &&
        decl.lineCount <= 35 &&
        (decl.parameterCount >= 3 || decl.score <= 4)) {
      reasons.add(
        'CROSS_FILE_SINGLE_CALLER(from ${p.basename(caller.filePath)})',
      );
    }
    return reasons;
  }

  /// Whether [decl] lives under `lib/` while [caller] lives in a consumer zone
  /// (`bin/`, `test/`, `tool/`, `example/`, `web/`). Such edges are normal
  /// package layering, not a shallow extraction.
  bool _isLibraryToConsumerEdge(ShallowDeclNode decl, ShallowDeclNode caller) {
    if (_zoneOf(decl.normalizedFilePath) != 'lib') return false;
    final callerZone = _zoneOf(caller.normalizedFilePath);
    return callerZone != 'lib' && callerZone != 'other';
  }

  List<_ScanFileEntry> _discoverScanFiles(
    List<String> targetPaths,
    Set<String>? modifiedFilesFilter,
  ) {
    final entriesByAbs = <String, _ScanFileEntry>{};
    final packageRoots = <String>{};

    for (final target in targetPaths) {
      final file = File(target);
      final dir = Directory(target);
      if (file.existsSync()) {
        _addFileEntry(
          entriesByAbs,
          file,
          isRequested: true,
          modifiedFilesFilter: modifiedFilesFilter,
        );
        packageRoots.addAll(_findEnclosingPackageRoot(file.parent.absolute));
      } else if (dir.existsSync()) {
        _collectDirEntries(
          entriesByAbs,
          dir,
          baseDir: target,
          isRequested: true,
          modifiedFilesFilter: modifiedFilesFilter,
        );
        packageRoots.addAll(_findEnclosingPackageRoot(dir.absolute));
      } else {
        throw FileSystemException('Path does not exist', target);
      }
    }

    for (final pkgRoot in packageRoots) {
      for (final sibling in _knownZones) {
        final sibDir = Directory(p.join(pkgRoot, sibling));
        _collectDirEntries(
          entriesByAbs,
          sibDir,
          baseDir: sibDir.path,
          isRequested: false,
          modifiedFilesFilter: modifiedFilesFilter,
        );
      }
    }

    final sorted = entriesByAbs.values.toList()
      ..sort((a, b) => a.absPath.compareTo(b.absPath));
    return sorted;
  }

  void _collectDirEntries(
    Map<String, _ScanFileEntry> entriesByAbs,
    Directory dir, {
    required String baseDir,
    required bool isRequested,
    required Set<String>? modifiedFilesFilter,
  }) {
    if (!dir.existsSync()) return;
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final relToTarget = p.relative(entity.path, from: baseDir);
      if (pathFilter.isExcluded(relToTarget)) continue;
      _addFileEntry(
        entriesByAbs,
        entity,
        isRequested: isRequested,
        modifiedFilesFilter: modifiedFilesFilter,
      );
    }
  }

  void _addFileEntry(
    Map<String, _ScanFileEntry> entriesByAbs,
    File file, {
    required bool isRequested,
    required Set<String>? modifiedFilesFilter,
  }) {
    if (p.extension(file.path) != '.dart') return;
    final absPath = p.normalize(file.absolute.path);
    final relFromCwd = p.relative(absPath);
    final displayPath = relFromCwd.startsWith('..') ? file.path : relFromCwd;
    final normDisplay = p.normalize(displayPath);
    final normSegments = p.split(normDisplay);
    if (normSegments.contains('fixtures') ||
        normSegments.contains('testdata')) {
      return;
    }

    final matchesFilter =
        modifiedFilesFilter == null ||
        modifiedFilesFilter.contains(normDisplay) ||
        modifiedFilesFilter.contains(absPath);
    final effectiveRequested = isRequested && matchesFilter;

    final existing = entriesByAbs[absPath];
    if (existing != null) {
      if (effectiveRequested && !existing.isInRequestedTargets) {
        entriesByAbs[absPath] = _ScanFileEntry(
          absPath: existing.absPath,
          displayPath: file.path,
          normalizedPath: existing.normalizedPath,
          isTestFile: existing.isTestFile,
          isPublicEntryFile: existing.isPublicEntryFile,
          isInRequestedTargets: true,
        );
      }
      return;
    }

    entriesByAbs[absPath] = _ScanFileEntry(
      absPath: absPath,
      displayPath: isRequested ? file.path : displayPath,
      normalizedPath: normDisplay,
      isTestFile:
          normSegments.contains('test') || normDisplay.endsWith('_test.dart'),
      isPublicEntryFile: _isPublicLibEntryPath(normSegments, absPath),
      isInRequestedTargets: effectiveRequested,
    );
  }

  Iterable<String> _findEnclosingPackageRoot(Directory startAbsDir) {
    var current = startAbsDir;
    for (var i = 0; i < 6; i++) {
      if (File(p.join(current.path, 'pubspec.yaml')).existsSync()) {
        return [current.path];
      }
      final parent = current.parent;
      if (parent.path == current.path) break;
      current = parent;
    }
    return const [];
  }
}

/// Builds the report ordering: classification, then caller groups ranked by
/// their most significant finding, then the caller, then simulation order.
/// Within one caller the printed order therefore matches the order in which
/// siblings were absorbed, so a `Caller CC: N (base B)` line never precedes
/// the sibling that produced `N`.
Comparator<ShallowFinding> _buildFindingComparator(
  List<ShallowFinding> findings,
) {
  final groupRank = <String, int>{};
  for (final f in findings) {
    final key = _callerKey(f);
    final rank = _significanceRank(f);
    final existing = groupRank[key];
    if (existing == null || rank < existing) groupRank[key] = rank;
  }
  return (a, b) {
    final classCmp = a.classification.index.compareTo(b.classification.index);
    if (classCmp != 0) return classCmp;
    final aKey = _callerKey(a);
    final bKey = _callerKey(b);
    final rankCmp = groupRank[aKey]!.compareTo(groupRank[bKey]!);
    if (rankCmp != 0) return rankCmp;
    final keyCmp = aKey.compareTo(bKey);
    if (keyCmp != 0) return keyCmp;
    return a.simulationIndex.compareTo(b.simulationIndex);
  };
}

String _callerKey(ShallowFinding f) => '${f.callerFilePath}#${f.callerName}';

/// `0` for arity/signature findings, `1` for findings that move the caller's
/// score, `2` for `+0` micro-predicates.
int _significanceRank(ShallowFinding f) {
  if (f.reasons.any(
    (r) => r.startsWith('HIGH_ARITY') || r.startsWith('SIG_HEAVY'),
  )) {
    return 0;
  }
  return f.inlinedDeltaScore != 0 ? 1 : 2;
}

bool _isPublicLibEntryPath(List<String> normParts, String absPath) {
  final libIdx = normParts.lastIndexOf('lib');
  if (libIdx >= 0 && libIdx == normParts.length - 2) return true;
  final absParts = p.split(absPath);
  final absLibIdx = absParts.lastIndexOf('lib');
  return absLibIdx >= 0 && absLibIdx == absParts.length - 2;
}

class _ScanFileEntry {
  final String absPath;
  final String displayPath;
  final String normalizedPath;
  final bool isTestFile;
  final bool isPublicEntryFile;
  final bool isInRequestedTargets;

  const _ScanFileEntry({
    required this.absPath,
    required this.displayPath,
    required this.normalizedPath,
    required this.isTestFile,
    required this.isPublicEntryFile,
    required this.isInRequestedTargets,
  });
}

class _RawCandidate {
  final ShallowDeclNode decl;
  final ShallowDeclNode caller;
  final ShallowCallSite call;
  final int baseDeltaScore;
  final int estimatedLinesSaved;
  final List<String> reasons;
  final String? sharedParamSignatureWith;
  final int sharedParamCount;
  final String? paramsSubsetOfExistingType;

  const _RawCandidate({
    required this.decl,
    required this.caller,
    required this.call,
    required this.baseDeltaScore,
    required this.estimatedLinesSaved,
    required this.reasons,
    required this.sharedParamSignatureWith,
    required this.sharedParamCount,
    required this.paramsSubsetOfExistingType,
  });
}

const _knownZones = {
  'lib',
  'bin',
  'test',
  'tool',
  'example',
  'web',
  'benchmark',
};

/// Classifies a normalized relative Dart file path by its package layout
/// directory: `lib`, `bin`, `test`, `tool`, `example`, `web`, `benchmark`, or
/// `other` when no such segment is present. The last matching segment wins so
/// nested packages (`tool/lib/x.dart`) resolve to their own layout directory.
String _zoneOf(String normalizedFilePath) {
  final segments = p.split(normalizedFilePath);
  for (var i = segments.length - 2; i >= 0; i--) {
    if (_knownZones.contains(segments[i])) return segments[i];
  }
  return 'other';
}

int _compareRawCandidates(_RawCandidate a, _RawCandidate b) {
  final aStructural = a.estimatedLinesSaved > 6;
  final bStructural = b.estimatedLinesSaved > 6;
  if (aStructural != bStructural) return aStructural ? -1 : 1;
  final deltaCmp = a.baseDeltaScore.compareTo(b.baseDeltaScore);
  if (deltaCmp != 0) return deltaCmp;
  final savedCmp = b.estimatedLinesSaved.compareTo(a.estimatedLinesSaved);
  if (savedCmp != 0) return savedCmp;
  final fileCmp = a.decl.filePath.compareTo(b.decl.filePath);
  if (fileCmp != 0) return fileCmp;
  return a.decl.startLine.compareTo(b.decl.startLine);
}

List<_RawCandidate> _orderBottomUp(List<_RawCandidate> candidates) {
  final ordered = <_RawCandidate>[];
  final visited = <_RawCandidate>{};

  void visit(_RawCandidate current) {
    if (!visited.add(current)) return;
    for (final child in candidates) {
      if (identical(child.caller, current.decl)) {
        visit(child);
      }
    }
    ordered.add(current);
  }

  for (final c in candidates) {
    visit(c);
  }
  return ordered;
}
