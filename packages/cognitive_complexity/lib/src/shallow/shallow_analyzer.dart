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
      final parsed = _tryParseFile(entry.absPath);
      if (parsed == null) continue;
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
      }
      for (final call in collector.calls) {
        callsByName.putIfAbsent(call.calleeName, () => []).add(call);
      }
    }

    final declsByName = <String, List<ShallowDeclNode>>{};
    for (final d in allDecls) {
      declsByName.putIfAbsent(d.rawName, () => []).add(d);
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
      );
      if (candidate != null) rawCandidates.add(candidate);
    }

    final findings = _resolveCumulativeCandidates(rawCandidates)
      ..sort(_compareFindings);
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

    return _RawCandidate(
      decl: decl,
      caller: caller,
      call: call,
      baseDeltaScore: baseDeltaScore,
      estimatedLinesSaved: estLinesSaved,
      reasons: reasons,
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

    for (final c in ordered) {
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
        c.toFinding(
          callerBaseScore: c.caller.score,
          callerCumulativeBefore: callerScore,
          callerScore: callerScore,
          deltaScore: deltaScore,
          inlinedCallerScore: inlinedCallerScore,
          classification: classification,
        ),
      );
    }
    return findings;
  }

  ShallowClassification _classifyInlinedScore({
    required int inlinedCallerScore,
    required int helperScore,
    required int callNestingDepth,
    required bool hasAbsorbedChildren,
  }) {
    if (inlinedCallerScore <= maxCallerScore) {
      return ShallowClassification.safeInline;
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
    if (decl.parameterCount >= maxParams) {
      reasons.add('HIGH_ARITY(${decl.parameterCount} params)');
    }
    if (decl.bodyLines <= 6 && decl.score <= 2) {
      reasons.add('MICRO_HELPER(${decl.bodyLines} bodyL, CC=${decl.score})');
    }
    if (decl.parameterCount >= 3 && decl.signatureLines >= decl.bodyLines - 2) {
      reasons.add(
        'SIG_HEAVY(sig=${decl.signatureLines}L vs body=${decl.bodyLines}L)',
      );
    }
    final isStandaloneHelper = decl.enclosingType == null || decl.isStatic;
    if (isStandaloneHelper &&
        caller.normalizedFilePath != decl.normalizedFilePath &&
        decl.lineCount <= 35 &&
        (decl.parameterCount >= 3 || decl.score <= 4)) {
      reasons.add(
        'CROSS_FILE_SINGLE_CALLER(from ${p.basename(caller.filePath)})',
      );
    }
    return reasons;
  }

  ParseStringResult? _tryParseFile(String absPath) {
    try {
      return parseFile(
        path: absPath,
        featureSet: _featureSet,
        throwIfDiagnostics: false,
      );
    } catch (_) {
      return null;
    }
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
      for (final sibling in const ['lib', 'bin', 'tool', 'test']) {
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
        entriesByAbs[absPath] = existing.withRequested(file.path);
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

int _compareFindings(ShallowFinding a, ShallowFinding b) {
  final classCmp = a.classification.index.compareTo(b.classification.index);
  if (classCmp != 0) return classCmp;
  final savedCmp = b.estimatedLinesSaved.compareTo(a.estimatedLinesSaved);
  if (savedCmp != 0) return savedCmp;
  final fileCmp = a.filePath.compareTo(b.filePath);
  if (fileCmp != 0) return fileCmp;
  return a.startLine.compareTo(b.startLine);
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

  _ScanFileEntry withRequested(String preferredDisplayPath) => _ScanFileEntry(
    absPath: absPath,
    displayPath: preferredDisplayPath,
    normalizedPath: normalizedPath,
    isTestFile: isTestFile,
    isPublicEntryFile: isPublicEntryFile,
    isInRequestedTargets: true,
  );
}

class _RawCandidate {
  final ShallowDeclNode decl;
  final ShallowDeclNode caller;
  final ShallowCallSite call;
  final int baseDeltaScore;
  final int estimatedLinesSaved;
  final List<String> reasons;

  const _RawCandidate({
    required this.decl,
    required this.caller,
    required this.call,
    required this.baseDeltaScore,
    required this.estimatedLinesSaved,
    required this.reasons,
  });

  ShallowFinding toFinding({
    required int callerBaseScore,
    required int callerCumulativeBefore,
    required int callerScore,
    required int deltaScore,
    required int inlinedCallerScore,
    required ShallowClassification classification,
  }) => ShallowFinding(
    filePath: decl.filePath,
    name: decl.qualifiedName,
    startLine: decl.startLine,
    endLine: decl.endLine,
    parameterCount: decl.parameterCount,
    namedParameterCount: decl.namedParameterCount,
    signatureLines: decl.signatureLines,
    bodyLines: decl.bodyLines,
    score: decl.score,
    callerFilePath: call.filePath,
    callerName: caller.qualifiedName,
    callLine: call.line,
    callNestingDepth: call.nestingDepth,
    callerBaseScore: callerBaseScore,
    callerCumulativeBefore: callerCumulativeBefore,
    callerScore: callerScore,
    inlinedDeltaScore: deltaScore,
    inlinedCallerScore: inlinedCallerScore,
    estimatedLinesSaved: estimatedLinesSaved,
    classification: classification,
    reasons: reasons,
  );
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
