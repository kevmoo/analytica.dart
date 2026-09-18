import 'dart:math' as math;

import 'models.dart';
import 'tokenizer.dart';

/// A contiguous span of tokens within a specific file.
class TokenSpan {
  final int fileIndex;
  final int startTokenIndex;
  final int endTokenIndex;

  const TokenSpan({
    required this.fileIndex,
    required this.startTokenIndex,
    required this.endTokenIndex,
  });

  int get tokenCount => endTokenIndex - startTokenIndex + 1;

  bool contains(TokenSpan other) {
    if (fileIndex != other.fileIndex) return false;
    return startTokenIndex <= other.startTokenIndex &&
        endTokenIndex >= other.endTokenIndex;
  }

  bool overlaps(TokenSpan other) {
    if (fileIndex != other.fileIndex) return false;
    return math.max(startTokenIndex, other.startTokenIndex) <=
        math.min(endTokenIndex, other.endTokenIndex);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TokenSpan &&
          fileIndex == other.fileIndex &&
          startTokenIndex == other.startTokenIndex &&
          endTokenIndex == other.endTokenIndex;

  @override
  int get hashCode => Object.hash(fileIndex, startTokenIndex, endTokenIndex);

  @override
  String toString() => '[$fileIndex:$startTokenIndex-$endTokenIndex]';
}

/// A pair of matching token spans representing a duplicate relationship.
class MatchPair {
  final TokenSpan span1;
  final TokenSpan span2;

  const MatchPair(this.span1, this.span2);

  bool isSubsumedBy(MatchPair other) {
    return (other.span1.contains(span1) && other.span2.contains(span2)) ||
        (other.span1.contains(span2) && other.span2.contains(span1));
  }

  bool isSubsumedByOrOverlaps(
    MatchPair other, {
    double minOverlapFraction = 0.70,
  }) {
    if (isSubsumedBy(other)) return true;

    if (span1.fileIndex == other.span1.fileIndex &&
        span2.fileIndex == other.span2.fileIndex) {
      return _spansOverlapSufficiently(
        span1,
        other.span1,
        span2,
        other.span2,
        minOverlapFraction,
      );
    }
    if (span1.fileIndex == other.span2.fileIndex &&
        span2.fileIndex == other.span1.fileIndex) {
      return _spansOverlapSufficiently(
        span1,
        other.span2,
        span2,
        other.span1,
        minOverlapFraction,
      );
    }
    return false;
  }

  static bool _spansOverlapSufficiently(
    TokenSpan s1,
    TokenSpan o1,
    TokenSpan s2,
    TokenSpan o2,
    double minOverlapFraction,
  ) {
    if (!s1.overlaps(o1) || !s2.overlaps(o2)) return false;
    final count1 = _overlapTokenCount(s1, o1);
    final count2 = _overlapTokenCount(s2, o2);
    return count1 / s1.tokenCount >= minOverlapFraction &&
        count2 / s2.tokenCount >= minOverlapFraction;
  }

  static int _overlapTokenCount(TokenSpan s1, TokenSpan s2) {
    final start = math.max(s1.startTokenIndex, s2.startTokenIndex);
    final end = math.min(s1.endTokenIndex, s2.endTokenIndex);
    return math.max(0, end - start + 1);
  }
}

/// Disjoint Set Union (DSU) helper for clustering token spans.
class SpanDsu {
  final List<TokenSpan> spanNodes = [];
  final Map<TokenSpan, int> _spanToIndex = {};
  final Map<int, int> parent = {};

  int getOrAddSpanNode(TokenSpan span) {
    final existing = _spanToIndex[span];
    if (existing != null) return existing;
    final newIdx = spanNodes.length;
    spanNodes.add(span);
    _spanToIndex[span] = newIdx;
    parent[newIdx] = newIdx;
    return newIdx;
  }

  int find(int i) {
    var root = i;
    while (parent[root] != root) {
      root = parent[root]!;
    }
    var curr = i;
    while (curr != root) {
      final nxt = parent[curr]!;
      parent[curr] = root;
      curr = nxt;
    }
    return root;
  }

  void union(int i, int j) {
    final rootI = find(i);
    final rootJ = find(j);
    if (rootI != rootJ) {
      parent[rootJ] = rootI;
    }
  }

  Map<int, List<TokenSpan>> groupClusters() {
    final clusterMap = <int, List<TokenSpan>>{};
    for (var i = 0; i < spanNodes.length; i++) {
      final root = find(i);
      clusterMap.putIfAbsent(root, () => []).add(spanNodes[i]);
    }
    return clusterMap;
  }
}

List<MatchPair> filterSubsumedPairs(List<MatchPair> rawPairs) {
  rawPairs.sort((a, b) => b.span1.tokenCount.compareTo(a.span1.tokenCount));
  final nonSubsumedPairs = <MatchPair>[];
  final pairsByFilePair = <(int, int), List<MatchPair>>{};

  for (final pair in rawPairs) {
    final fileKey = pair.span1.fileIndex <= pair.span2.fileIndex
        ? (pair.span1.fileIndex, pair.span2.fileIndex)
        : (pair.span2.fileIndex, pair.span1.fileIndex);
    final existingForFile = pairsByFilePair[fileKey];

    var isSubsumed = false;
    if (existingForFile != null) {
      for (final existing in existingForFile) {
        if (pair.isSubsumedByOrOverlaps(existing)) {
          isSubsumed = true;
          break;
        }
      }
    }
    if (!isSubsumed) {
      nonSubsumedPairs.add(pair);
      pairsByFilePair.putIfAbsent(fileKey, () => []).add(pair);
    }
  }
  return nonSubsumedPairs;
}

List<DuplicateCluster> createClustersFromSpanGroups(
  Map<int, List<TokenSpan>> clusterMap,
  List<TokenSequence> fileSequences,
) {
  final rawClusters = <DuplicateCluster>[];
  var clusterIndex = 1;

  for (final spans in clusterMap.values) {
    final cluster = _buildSingleCluster(
      clusterIndex: clusterIndex,
      spans: spans,
      fileSequences: fileSequences,
    );
    if (cluster != null) {
      rawClusters.add(cluster);
      clusterIndex++;
    }
  }

  final deduplicated = _mergeAndDeduplicateClusters(rawClusters);

  deduplicated.sort((a, b) {
    final comp = b.estimatedLinesSaved.compareTo(a.estimatedLinesSaved);
    if (comp != 0) return comp;
    return b.tokenCount.compareTo(a.tokenCount);
  });

  final finalClusters = <DuplicateCluster>[];
  for (var i = 0; i < deduplicated.length; i++) {
    final c = deduplicated[i];
    finalClusters.add(
      DuplicateCluster(
        id: 'cluster-${i + 1}',
        instances: c.instances,
        tokenCount: c.tokenCount,
        lineCount: c.lineCount,
        category: c.category,
        bucket: c.bucket,
        estimatedLinesSaved: c.estimatedLinesSaved,
        intersectsDiff: c.intersectsDiff,
        isNewlyIntroduced: c.isNewlyIntroduced,
      ),
    );
  }

  return finalClusters;
}

List<DuplicateCluster> _mergeAndDeduplicateClusters(
  List<DuplicateCluster> clusters,
) {
  if (clusters.length <= 1) return clusters;

  final sorted = List<DuplicateCluster>.from(clusters)
    ..sort((a, b) {
      final c1 = b.instances.length.compareTo(a.instances.length);
      if (c1 != 0) return c1;
      final c2 = b.lineCount.compareTo(a.lineCount);
      if (c2 != 0) return c2;
      return b.tokenCount.compareTo(a.tokenCount);
    });

  final kept = <DuplicateCluster>[];

  for (final candidate in sorted) {
    var isRedundant = false;

    for (final existing in kept) {
      if (_isClusterSubsumedOrDuplicate(candidate, existing)) {
        isRedundant = true;
        break;
      }
    }

    if (!isRedundant) {
      kept.add(candidate);
    }
  }

  return kept;
}

bool _isClusterSubsumedOrDuplicate(
  DuplicateCluster candidate,
  DuplicateCluster existing,
) {
  if (candidate.instances.length > existing.instances.length) {
    return false;
  }

  final usedExistingIndices = <int>{};
  for (final cInst in candidate.instances) {
    final matchIndex = _findMatchingExistingInstance(
      cInst,
      existing.instances,
      usedExistingIndices,
    );
    if (matchIndex == null) return false;
    usedExistingIndices.add(matchIndex);
  }

  return true;
}

int? _findMatchingExistingInstance(
  CloneInstance cInst,
  List<CloneInstance> existingInstances,
  Set<int> usedIndices,
) {
  for (var i = 0; i < existingInstances.length; i++) {
    if (usedIndices.contains(i)) continue;
    if (_instancesOverlapSufficiently(cInst, existingInstances[i])) {
      return i;
    }
  }
  return null;
}

bool _instancesOverlapSufficiently(CloneInstance cInst, CloneInstance eInst) {
  if (cInst.filePath != eInst.filePath) return false;
  final overlapStart = math.max(cInst.startLine, eInst.startLine);
  final overlapEnd = math.min(cInst.endLine, eInst.endLine);
  if (overlapStart > overlapEnd) return false;

  final overlapLines = overlapEnd - overlapStart + 1;
  final frac = overlapLines / cInst.lineCount;
  return frac >= 0.70 ||
      (eInst.startLine <= cInst.startLine && eInst.endLine >= cInst.endLine);
}

DuplicateCluster? _buildSingleCluster({
  required int clusterIndex,
  required List<TokenSpan> spans,
  required List<TokenSequence> fileSequences,
}) {
  if (spans.length < 2) return null;

  final dedupedSpans = _deduplicateOverlappingSpans(spans);
  if (dedupedSpans.length < 2) return null;

  final instances = dedupedSpans
      .map((span) => _createInstance(span, fileSequences[span.fileIndex]))
      .toList();

  final bucket = _determineBucket(dedupedSpans, fileSequences);
  final repTokens = fileSequences[dedupedSpans.first.fileIndex].tokens.sublist(
    dedupedSpans.first.startTokenIndex,
    dedupedSpans.first.endTokenIndex + 1,
  );
  final category = _classifyCategory(repTokens);
  final avgLineCount =
      (instances.map((i) => i.lineCount).reduce((a, b) => a + b) /
              instances.length)
          .round();
  final estimatedLinesSaved = instances
      .skip(1)
      .fold<int>(0, (sum, i) => sum + i.lineCount);

  return DuplicateCluster(
    id: 'cluster-$clusterIndex',
    instances: instances,
    tokenCount: dedupedSpans.first.tokenCount,
    lineCount: avgLineCount,
    category: category,
    bucket: bucket,
    estimatedLinesSaved: estimatedLinesSaved,
  );
}

List<TokenSpan> _deduplicateOverlappingSpans(List<TokenSpan> spans) {
  if (spans.isEmpty) return const [];

  final byFile = <int, List<TokenSpan>>{};
  for (final s in spans) {
    byFile.putIfAbsent(s.fileIndex, () => []).add(s);
  }

  final deduped = <TokenSpan>[];
  for (final fileSpans in byFile.values) {
    fileSpans.sort((a, b) => a.startTokenIndex.compareTo(b.startTokenIndex));

    var current = fileSpans.first;
    for (var i = 1; i < fileSpans.length; i++) {
      final next = fileSpans[i];
      if (current.overlaps(next)) {
        current = TokenSpan(
          fileIndex: current.fileIndex,
          startTokenIndex: math.min(
            current.startTokenIndex,
            next.startTokenIndex,
          ),
          endTokenIndex: math.max(current.endTokenIndex, next.endTokenIndex),
        );
      } else {
        deduped.add(current);
        current = next;
      }
    }
    deduped.add(current);
  }
  return deduped;
}

CloneInstance _createInstance(TokenSpan span, TokenSequence seq) {
  final startToken = seq.tokens[span.startTokenIndex];
  final endToken = seq.tokens[span.endTokenIndex];
  final startLine = startToken.startLine;
  final endLine = endToken.endLine;
  final lineCount = endLine - startLine + 1;
  final snippet = seq.getSnippetForTokens(
    span.startTokenIndex,
    span.endTokenIndex,
  );

  return CloneInstance(
    filePath: seq.filePath,
    startLine: startLine,
    endLine: endLine,
    startColumn: startToken.startColumn,
    endColumn: endToken.endColumn,
    tokenCount: span.tokenCount,
    lineCount: lineCount,
    snippet: snippet,
  );
}

CloneBucket _determineBucket(
  List<TokenSpan> spans,
  List<TokenSequence> fileSequences,
) {
  var isIdentical = true;
  var isStructural = true;
  var isParameterized = true;

  final firstSeq = fileSequences[spans.first.fileIndex];
  final firstTokens = firstSeq.tokens;
  final firstStart = spans.first.startTokenIndex;
  final tokenCount = spans.first.tokenCount;

  for (var sIdx = 1; sIdx < spans.length; sIdx++) {
    final otherSpan = spans[sIdx];
    if (otherSpan.tokenCount != tokenCount) {
      return CloneBucket.gapped;
    }

    final otherSeq = fileSequences[otherSpan.fileIndex];
    final otherTokens = otherSeq.tokens;
    final otherStart = otherSpan.startTokenIndex;

    final (identical, structural, parameterized) = _compareSpanTokens(
      firstTokens,
      firstStart,
      otherTokens,
      otherStart,
      tokenCount,
    );

    if (!identical) isIdentical = false;
    if (!structural) isStructural = false;
    if (!parameterized) isParameterized = false;
  }

  if (isIdentical) return CloneBucket.identical;
  if (isStructural) return CloneBucket.structural;
  if (isParameterized) return CloneBucket.parameterized;
  return CloneBucket.gapped;
}

(bool, bool, bool) _compareSpanTokens(
  List<NormalizedToken> tokens1,
  int start1,
  List<NormalizedToken> tokens2,
  int start2,
  int tokenCount,
) {
  var isIdentical = true;
  var isStructural = true;
  var isParameterized = true;

  for (var t = 0; t < tokenCount; t++) {
    final tok1 = tokens1[start1 + t];
    final tok2 = tokens2[start2 + t];

    if (tok1.originalLexeme != tok2.originalLexeme) {
      isIdentical = false;
    }
    if (tok1.normalizedLexeme == '<ID>' &&
        tok2.normalizedLexeme == '<ID>' &&
        tok1.originalLexeme != tok2.originalLexeme) {
      isStructural = false;
    }
    if (tok1.normalizedLexeme != tok2.normalizedLexeme) {
      isParameterized = false;
    }
  }

  return (isIdentical, isStructural, isParameterized);
}

CloneCategory _classifyCategory(List<NormalizedToken> tokens) {
  var controlFlowCount = 0;
  var dataLiteralCount = 0;
  var boilerplateCount = 0;

  for (final tok in tokens) {
    final lexeme = tok.originalLexeme;
    if (lexeme == 'if' ||
        lexeme == 'for' ||
        lexeme == 'while' ||
        lexeme == 'switch' ||
        lexeme == 'case' ||
        lexeme == 'return' ||
        lexeme == 'try' ||
        lexeme == 'catch' ||
        lexeme == 'await' ||
        lexeme == 'yield') {
      controlFlowCount++;
    } else if (tok.normalizedLexeme == '<STR>' ||
        tok.normalizedLexeme == '<NUM>' ||
        lexeme == ':' ||
        lexeme == '[' ||
        lexeme == ']' ||
        lexeme == '{' ||
        lexeme == '}') {
      dataLiteralCount++;
    } else if (lexeme == 'import' ||
        lexeme == 'export' ||
        lexeme == 'part' ||
        lexeme == 'typedef' ||
        lexeme == 'library') {
      boilerplateCount++;
    }
  }

  if (boilerplateCount > 0 && boilerplateCount >= controlFlowCount) {
    return CloneCategory.boilerplate;
  }

  if (controlFlowCount > 0) {
    return CloneCategory.logic;
  }

  if (dataLiteralCount > tokens.length / 2) {
    return CloneCategory.data;
  }

  return CloneCategory.logic;
}
