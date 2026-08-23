import 'dart:math' as math;

import 'ast_extractor.dart';
import 'minhash.dart';
import 'models.dart';
import 'tokenizer.dart';

/// Internal representation of a token location.
class _TokenLocation {
  final int fileIndex;
  final int tokenIndex;

  const _TokenLocation(this.fileIndex, this.tokenIndex);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _TokenLocation &&
          fileIndex == other.fileIndex &&
          tokenIndex == other.tokenIndex;

  @override
  int get hashCode => Object.hash(fileIndex, tokenIndex);

  @override
  String toString() => '($fileIndex, $tokenIndex)';
}

/// A contiguous span of tokens within a specific file.
class _TokenSpan {
  final int fileIndex;
  final int startTokenIndex;
  final int endTokenIndex;

  const _TokenSpan({
    required this.fileIndex,
    required this.startTokenIndex,
    required this.endTokenIndex,
  });

  int get tokenCount => endTokenIndex - startTokenIndex + 1;

  bool contains(_TokenSpan other) {
    if (fileIndex != other.fileIndex) return false;
    return startTokenIndex <= other.startTokenIndex &&
        endTokenIndex >= other.endTokenIndex;
  }

  bool overlaps(_TokenSpan other) {
    if (fileIndex != other.fileIndex) return false;
    return math.max(startTokenIndex, other.startTokenIndex) <=
        math.min(endTokenIndex, other.endTokenIndex);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _TokenSpan &&
          fileIndex == other.fileIndex &&
          startTokenIndex == other.startTokenIndex &&
          endTokenIndex == other.endTokenIndex;

  @override
  int get hashCode => Object.hash(fileIndex, startTokenIndex, endTokenIndex);

  @override
  String toString() => '[$fileIndex:$startTokenIndex-$endTokenIndex]';
}

/// A pair of matching token spans representing a duplicate relationship.
class _MatchPair {
  final _TokenSpan span1;
  final _TokenSpan span2;

  const _MatchPair(this.span1, this.span2);

  bool isSubsumedBy(_MatchPair other) {
    return (other.span1.contains(span1) && other.span2.contains(span2)) ||
        (other.span1.contains(span2) && other.span2.contains(span1));
  }
}

/// Disjoint Set Union (DSU) helper for clustering token spans.
class _SpanDsu {
  final List<_TokenSpan> spanNodes = [];
  final Map<_TokenSpan, int> _spanToIndex = {};
  final Map<int, int> parent = {};

  int getOrAddSpanNode(_TokenSpan span) {
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

  Map<int, List<_TokenSpan>> groupClusters() {
    final clusterMap = <int, List<_TokenSpan>>{};
    for (var i = 0; i < spanNodes.length; i++) {
      final root = find(i);
      clusterMap.putIfAbsent(root, () => []).add(spanNodes[i]);
    }
    return clusterMap;
  }
}

/// Core clone detection engine using $k$-gram polynomial rolling hashes and
/// maximal bidirectional extension.
class CloneDetector {
  final int minTokens;
  final int minLines;

  static const int _primeBase = 31337;
  static const int _hashMask = 0x7FFFFFFFFFFFFFFF;

  const CloneDetector({this.minTokens = 40, this.minLines = 4});

  /// Detects all duplicate clusters across [fileSequences].
  List<DuplicateCluster> detect(
    List<TokenSequence> fileSequences, {
    List<AstCandidateUnit>? candidates,
  }) {
    if (fileSequences.isEmpty) return const [];

    final rawPairs = <_MatchPair>[];
    final seenPairs = <int>{};

    if (candidates != null && candidates.isNotEmpty) {
      _matchAstCandidates(
        candidates: candidates,
        fileSequences: fileSequences,
        seenPairs: seenPairs,
        outPairs: rawPairs,
      );
      _matchMinHashCandidates(
        candidates: candidates,
        fileSequences: fileSequences,
        seenPairs: seenPairs,
        outPairs: rawPairs,
      );
    }

    final k = math.max(5, minTokens);
    final basePow = _computeBasePow(k);
    final index = _buildKgramIndex(fileSequences, k, basePow);
    _collectKgramMatches(
      index: index,
      fileSequences: fileSequences,
      k: k,
      minTokens: minTokens,
      minLines: minLines,
      seenPairs: seenPairs,
      outPairs: rawPairs,
    );

    if (rawPairs.isEmpty) return const [];

    final nonSubsumedPairs = _filterSubsumedPairs(rawPairs);
    final dsu = _SpanDsu();
    for (final pair in nonSubsumedPairs) {
      final idx1 = dsu.getOrAddSpanNode(pair.span1);
      final idx2 = dsu.getOrAddSpanNode(pair.span2);
      dsu.union(idx1, idx2);
    }

    final clusterMap = dsu.groupClusters();
    final clusters = _createClustersFromSpanGroups(clusterMap, fileSequences);

    clusters.sort((a, b) {
      final comp = b.estimatedLinesSaved.compareTo(a.estimatedLinesSaved);
      if (comp != 0) return comp;
      return b.tokenCount.compareTo(a.tokenCount);
    });

    return clusters;
  }

  static void _matchAstCandidates({
    required List<AstCandidateUnit> candidates,
    required List<TokenSequence> fileSequences,
    required Set<int> seenPairs,
    required List<_MatchPair> outPairs,
  }) {
    final byHash = <int, List<AstCandidateUnit>>{};
    for (final c in candidates) {
      byHash.putIfAbsent(c.signatureHash, () => []).add(c);
    }

    for (final bucket in byHash.values) {
      if (bucket.length < 2 || bucket.length > 50) continue;
      _matchAstCandidateBucket(
        bucket: bucket,
        fileSequences: fileSequences,
        seenPairs: seenPairs,
        outPairs: outPairs,
      );
    }
  }

  static void _matchAstCandidateBucket({
    required List<AstCandidateUnit> bucket,
    required List<TokenSequence> fileSequences,
    required Set<int> seenPairs,
    required List<_MatchPair> outPairs,
  }) {
    for (var i = 0; i < bucket.length; i++) {
      final c1 = bucket[i];
      for (var j = i + 1; j < bucket.length; j++) {
        final c2 = bucket[j];
        _tryAddAstCandidatePair(
          c1: c1,
          c2: c2,
          fileSequences: fileSequences,
          seenPairs: seenPairs,
          outPairs: outPairs,
        );
      }
    }
  }

  static void _tryAddAstCandidatePair({
    required AstCandidateUnit c1,
    required AstCandidateUnit c2,
    required List<TokenSequence> fileSequences,
    required Set<int> seenPairs,
    required List<_MatchPair> outPairs,
  }) {
    if (c1.fileIndex == c2.fileIndex &&
        (c1.startTokenIndex <= c2.endTokenIndex &&
            c2.startTokenIndex <= c1.endTokenIndex)) {
      return;
    }

    if (!_compareCandidateTokens(c1, c2, fileSequences)) return;

    final span1 = _TokenSpan(
      fileIndex: c1.fileIndex,
      startTokenIndex: c1.startTokenIndex,
      endTokenIndex: c1.endTokenIndex,
    );
    final span2 = _TokenSpan(
      fileIndex: c2.fileIndex,
      startTokenIndex: c2.startTokenIndex,
      endTokenIndex: c2.endTokenIndex,
    );

    final pairKey = _computeSpanPairKey(span1, span2);
    if (seenPairs.add(pairKey)) {
      outPairs.add(_MatchPair(span1, span2));
    }
  }

  static void _matchMinHashCandidates({
    required List<AstCandidateUnit> candidates,
    required List<TokenSequence> fileSequences,
    required Set<int> seenPairs,
    required List<_MatchPair> outPairs,
    double minJaccard = 0.80,
  }) {
    final lshIndex = LshIndex<AstCandidateUnit>();
    for (final c in candidates) {
      if (c.minHashSignature.isNotEmpty) {
        lshIndex.insert(c, c.minHashSignature);
      }
    }

    final candidatePairs = lshIndex.findCandidatePairs();
    for (final pair in candidatePairs) {
      _tryAddMinHashCandidatePair(
        c1: pair.item1,
        c2: pair.item2,
        fileSequences: fileSequences,
        minJaccard: minJaccard,
        seenPairs: seenPairs,
        outPairs: outPairs,
      );
    }
  }

  static void _tryAddMinHashCandidatePair({
    required AstCandidateUnit c1,
    required AstCandidateUnit c2,
    required List<TokenSequence> fileSequences,
    required double minJaccard,
    required Set<int> seenPairs,
    required List<_MatchPair> outPairs,
  }) {
    if (c1.fileIndex == c2.fileIndex &&
        (c1.startTokenIndex <= c2.endTokenIndex &&
            c2.startTokenIndex <= c1.endTokenIndex)) {
      return;
    }

    final jaccard = MinHasher.exactJaccard(
      c1.statementHashes,
      c2.statementHashes,
    );
    if (jaccard < minJaccard) return;

    if (!_verifyMinHashCandidateTokens(c1, c2, fileSequences, minJaccard)) {
      return;
    }

    final span1 = _TokenSpan(
      fileIndex: c1.fileIndex,
      startTokenIndex: c1.startTokenIndex,
      endTokenIndex: c1.endTokenIndex,
    );
    final span2 = _TokenSpan(
      fileIndex: c2.fileIndex,
      startTokenIndex: c2.startTokenIndex,
      endTokenIndex: c2.endTokenIndex,
    );

    final pairKey = _computeSpanPairKey(span1, span2);
    if (seenPairs.add(pairKey)) {
      outPairs.add(_MatchPair(span1, span2));
    }
  }

  static bool _verifyMinHashCandidateTokens(
    AstCandidateUnit c1,
    AstCandidateUnit c2,
    List<TokenSequence> fileSequences,
    double minSimilarity,
  ) {
    final tokens1 = fileSequences[c1.fileIndex].tokens;
    final tokens2 = fileSequences[c2.fileIndex].tokens;

    const shingleSize = 2;
    if (c1.tokenCount < shingleSize || c2.tokenCount < shingleSize) {
      return _compareCandidateTokens(c1, c2, fileSequences);
    }

    final shingles1 = <int>{};
    for (var i = 0; i <= c1.tokenCount - shingleSize; i++) {
      final h1 = tokens1[c1.startTokenIndex + i].tokenHash;
      final h2 = tokens1[c1.startTokenIndex + i + 1].tokenHash;
      shingles1.add((h1 << 32) ^ (h2 & 0xFFFFFFFF));
    }

    final shingles2 = <int>{};
    for (var i = 0; i <= c2.tokenCount - shingleSize; i++) {
      final h1 = tokens2[c2.startTokenIndex + i].tokenHash;
      final h2 = tokens2[c2.startTokenIndex + i + 1].tokenHash;
      shingles2.add((h1 << 32) ^ (h2 & 0xFFFFFFFF));
    }

    final tokenJaccard = MinHasher.exactJaccard(shingles1, shingles2);
    return tokenJaccard >= minSimilarity;
  }

  static bool _compareCandidateTokens(
    AstCandidateUnit c1,
    AstCandidateUnit c2,
    List<TokenSequence> fileSequences,
  ) {
    if (c1.tokenCount != c2.tokenCount) return false;
    final tokens1 = fileSequences[c1.fileIndex].tokens;
    final tokens2 = fileSequences[c2.fileIndex].tokens;

    for (var i = 0; i < c1.tokenCount; i++) {
      if (tokens1[c1.startTokenIndex + i].normalizedLexeme !=
          tokens2[c2.startTokenIndex + i].normalizedLexeme) {
        return false;
      }
    }
    return true;
  }

  static int _computeBasePow(int k) {
    var basePow = 1;
    for (var i = 0; i < k - 1; i++) {
      basePow = (basePow * _primeBase) & _hashMask;
    }
    return basePow;
  }

  static Map<int, List<_TokenLocation>> _buildKgramIndex(
    List<TokenSequence> fileSequences,
    int k,
    int basePow,
  ) {
    final index = <int, List<_TokenLocation>>{};
    for (var f = 0; f < fileSequences.length; f++) {
      final tokens = fileSequences[f].tokens;
      if (tokens.length < k) continue;

      var currentHash = 0;
      for (var i = 0; i < k; i++) {
        currentHash =
            ((currentHash * _primeBase) + tokens[i].tokenHash) & _hashMask;
      }
      index.putIfAbsent(currentHash, () => []).add(_TokenLocation(f, 0));

      for (var i = 1; i <= tokens.length - k; i++) {
        final prevHash = (tokens[i - 1].tokenHash * basePow) & _hashMask;
        var nextHash = (currentHash - prevHash) & _hashMask;
        if (nextHash < 0) nextHash = (nextHash + _hashMask) & _hashMask;
        nextHash =
            ((nextHash * _primeBase) + tokens[i + k - 1].tokenHash) & _hashMask;
        currentHash = nextHash;

        index.putIfAbsent(currentHash, () => []).add(_TokenLocation(f, i));
      }
    }
    return index;
  }

  static void _collectKgramMatches({
    required Map<int, List<_TokenLocation>> index,
    required List<TokenSequence> fileSequences,
    required int k,
    required int minTokens,
    required int minLines,
    required Set<int> seenPairs,
    required List<_MatchPair> outPairs,
  }) {
    for (final locations in index.values) {
      if (locations.length < 2) continue;
      // Cap oversized buckets to prevent combinatorial explosion on trivial
      // boilerplate.
      if (locations.length > 50) continue;

      _collectMatchesForBucket(
        locations: locations,
        fileSequences: fileSequences,
        k: k,
        minTokens: minTokens,
        minLines: minLines,
        seenPairs: seenPairs,
        outPairs: outPairs,
      );
    }
  }

  static void _collectMatchesForBucket({
    required List<_TokenLocation> locations,
    required List<TokenSequence> fileSequences,
    required int k,
    required int minTokens,
    required int minLines,
    required Set<int> seenPairs,
    required List<_MatchPair> outPairs,
  }) {
    for (var i = 0; i < locations.length; i++) {
      final loc1 = locations[i];
      for (var j = i + 1; j < locations.length; j++) {
        final loc2 = locations[j];
        _processLocationPair(
          loc1: loc1,
          loc2: loc2,
          fileSequences: fileSequences,
          k: k,
          minTokens: minTokens,
          minLines: minLines,
          seenPairs: seenPairs,
          outPairs: outPairs,
        );
      }
    }
  }

  static void _processLocationPair({
    required _TokenLocation loc1,
    required _TokenLocation loc2,
    required List<TokenSequence> fileSequences,
    required int k,
    required int minTokens,
    required int minLines,
    required Set<int> seenPairs,
    required List<_MatchPair> outPairs,
  }) {
    final pairKey = _computeLocationPairKey(loc1, loc2);
    if (!seenPairs.add(pairKey)) return;

    final pair = _tryMatchPair(
      loc1: loc1,
      loc2: loc2,
      fileSequences: fileSequences,
      k: k,
      minTokens: minTokens,
      minLines: minLines,
    );
    if (pair == null) return;

    outPairs.add(pair);
    _markSubSeedsAsSeen(pair, k, seenPairs);
  }

  static int _computeLocationPairKey(_TokenLocation loc1, _TokenLocation loc2) {
    if (loc1.fileIndex <= loc2.fileIndex) {
      return Object.hash(
        loc1.fileIndex,
        loc1.tokenIndex,
        loc2.fileIndex,
        loc2.tokenIndex,
      );
    }
    return Object.hash(
      loc2.fileIndex,
      loc2.tokenIndex,
      loc1.fileIndex,
      loc1.tokenIndex,
    );
  }

  static int _computeSpanPairKey(_TokenSpan span1, _TokenSpan span2) {
    if (span1.fileIndex <= span2.fileIndex) {
      return Object.hash(
        span1.fileIndex,
        span1.startTokenIndex,
        span2.fileIndex,
        span2.startTokenIndex,
      );
    }
    return Object.hash(
      span2.fileIndex,
      span2.startTokenIndex,
      span1.fileIndex,
      span1.startTokenIndex,
    );
  }

  static void _markSubSeedsAsSeen(_MatchPair pair, int k, Set<int> seenPairs) {
    final maxOffset = pair.span1.tokenCount - k;
    final file1 = pair.span1.fileIndex;
    final file2 = pair.span2.fileIndex;
    final start1 = pair.span1.startTokenIndex;
    final start2 = pair.span2.startTokenIndex;

    for (var offset = 1; offset <= maxOffset; offset++) {
      final subKey = file1 <= file2
          ? Object.hash(file1, start1 + offset, file2, start2 + offset)
          : Object.hash(file2, start2 + offset, file1, start1 + offset);
      seenPairs.add(subKey);
    }
  }

  static _MatchPair? _tryMatchPair({
    required _TokenLocation loc1,
    required _TokenLocation loc2,
    required List<TokenSequence> fileSequences,
    required int k,
    required int minTokens,
    required int minLines,
  }) {
    if (loc1.fileIndex == loc2.fileIndex &&
        (loc1.tokenIndex - loc2.tokenIndex).abs() < k) {
      return null;
    }

    final tokens1 = fileSequences[loc1.fileIndex].tokens;
    final tokens2 = fileSequences[loc2.fileIndex].tokens;

    if (!_seedsMatch(tokens1, loc1.tokenIndex, tokens2, loc2.tokenIndex, k)) {
      return null;
    }

    final start1 = _extendBackward(tokens1, loc1, tokens2, loc2, k);
    final start2 = loc2.tokenIndex - (loc1.tokenIndex - start1);
    final end1 = _extendForward(tokens1, loc1, tokens2, loc2, k, start2);
    final end2 = loc2.tokenIndex + k - 1 + (end1 - (loc1.tokenIndex + k - 1));

    final span1 = _TokenSpan(
      fileIndex: loc1.fileIndex,
      startTokenIndex: start1,
      endTokenIndex: end1,
    );
    final span2 = _TokenSpan(
      fileIndex: loc2.fileIndex,
      startTokenIndex: start2,
      endTokenIndex: end2,
    );

    if (span1.tokenCount < minTokens) return null;

    final lineCount1 = tokens1[end1].endLine - tokens1[start1].startLine + 1;
    final lineCount2 = tokens2[end2].endLine - tokens2[start2].startLine + 1;
    if (lineCount1 < minLines || lineCount2 < minLines) return null;

    return _MatchPair(span1, span2);
  }

  static bool _seedsMatch(
    List<NormalizedToken> tokens1,
    int idx1,
    List<NormalizedToken> tokens2,
    int idx2,
    int k,
  ) {
    for (var m = 0; m < k; m++) {
      if (tokens1[idx1 + m].normalizedLexeme !=
          tokens2[idx2 + m].normalizedLexeme) {
        return false;
      }
    }
    return true;
  }

  static int _extendBackward(
    List<NormalizedToken> tokens1,
    _TokenLocation loc1,
    List<NormalizedToken> tokens2,
    _TokenLocation loc2,
    int k,
  ) {
    var start1 = loc1.tokenIndex;
    var start2 = loc2.tokenIndex;
    while (start1 > 0 && start2 > 0) {
      if (loc1.fileIndex == loc2.fileIndex &&
          start1 - 1 == loc2.tokenIndex + k - 1) {
        break;
      }
      if (tokens1[start1 - 1].normalizedLexeme !=
          tokens2[start2 - 1].normalizedLexeme) {
        break;
      }
      start1--;
      start2--;
    }
    return start1;
  }

  static int _extendForward(
    List<NormalizedToken> tokens1,
    _TokenLocation loc1,
    List<NormalizedToken> tokens2,
    _TokenLocation loc2,
    int k,
    int start2,
  ) {
    var end1 = loc1.tokenIndex + k - 1;
    var end2 = loc2.tokenIndex + k - 1;
    while (end1 + 1 < tokens1.length && end2 + 1 < tokens2.length) {
      if (loc1.fileIndex == loc2.fileIndex && end1 + 1 == start2) {
        break;
      }
      if (tokens1[end1 + 1].normalizedLexeme !=
          tokens2[end2 + 1].normalizedLexeme) {
        break;
      }
      end1++;
      end2++;
    }
    return end1;
  }

  static List<_MatchPair> _filterSubsumedPairs(List<_MatchPair> rawPairs) {
    rawPairs.sort((a, b) => b.span1.tokenCount.compareTo(a.span1.tokenCount));
    final nonSubsumedPairs = <_MatchPair>[];
    final pairsByFilePair = <int, List<_MatchPair>>{};

    for (final pair in rawPairs) {
      final fileKey = pair.span1.fileIndex <= pair.span2.fileIndex
          ? Object.hash(pair.span1.fileIndex, pair.span2.fileIndex)
          : Object.hash(pair.span2.fileIndex, pair.span1.fileIndex);
      final existingForFile = pairsByFilePair[fileKey];

      var isSubsumed = false;
      if (existingForFile != null) {
        for (final existing in existingForFile) {
          if (pair.isSubsumedBy(existing)) {
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

  static List<DuplicateCluster> _createClustersFromSpanGroups(
    Map<int, List<_TokenSpan>> clusterMap,
    List<TokenSequence> fileSequences,
  ) {
    final clusters = <DuplicateCluster>[];
    var clusterIndex = 1;

    for (final spans in clusterMap.values) {
      final cluster = _buildSingleCluster(
        clusterIndex: clusterIndex,
        spans: spans,
        fileSequences: fileSequences,
      );
      if (cluster != null) {
        clusters.add(cluster);
        clusterIndex++;
      }
    }
    return clusters;
  }

  static DuplicateCluster? _buildSingleCluster({
    required int clusterIndex,
    required List<_TokenSpan> spans,
    required List<TokenSequence> fileSequences,
  }) {
    if (spans.length < 2) return null;

    final dedupedSpans = _deduplicateOverlappingSpans(spans);
    if (dedupedSpans.length < 2) return null;

    final instances = dedupedSpans
        .map((span) => _createInstance(span, fileSequences[span.fileIndex]))
        .toList();

    final bucket = _determineBucket(dedupedSpans, fileSequences);
    final repTokens = fileSequences[dedupedSpans.first.fileIndex].tokens
        .sublist(
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

  static List<_TokenSpan> _deduplicateOverlappingSpans(List<_TokenSpan> spans) {
    final deduped = <_TokenSpan>[];
    for (final s in spans) {
      if (!deduped.any((existing) => existing.overlaps(s))) {
        deduped.add(s);
      }
    }
    return deduped;
  }

  static CloneInstance _createInstance(_TokenSpan span, TokenSequence seq) {
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

  static CloneBucket _determineBucket(
    List<_TokenSpan> spans,
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

  static (bool, bool, bool) _compareSpanTokens(
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

  static CloneCategory _classifyCategory(List<NormalizedToken> tokens) {
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
}
