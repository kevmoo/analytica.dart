import 'dart:math' as math;

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

/// Core clone detection engine using $k$-gram polynomial rolling hashes and
/// maximal bidirectional extension.
class CloneDetector {
  final int minTokens;
  final int minLines;

  static const int _primeBase = 31337;
  static const int _hashMask = 0x7FFFFFFFFFFFFFFF;

  const CloneDetector({this.minTokens = 40, this.minLines = 4});

  /// Detects all duplicate clusters across [fileSequences].
  List<DuplicateCluster> detect(List<TokenSequence> fileSequences) {
    if (fileSequences.isEmpty) return const [];

    final k = math.max(5, minTokens);
    final index = <int, List<_TokenLocation>>{};

    // Precalculate base^(k-1) % hashMask for O(1) rolling hash sliding window
    var basePow = 1;
    for (var i = 0; i < k - 1; i++) {
      basePow = (basePow * _primeBase) & _hashMask;
    }

    // 1. Build k-gram index across all files
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

    // 2. Discover and maximally extend matching pairs
    final rawPairs = <_MatchPair>[];

    for (final locations in index.values) {
      if (locations.length < 2) continue;

      for (var i = 0; i < locations.length; i++) {
        final loc1 = locations[i];
        final tokens1 = fileSequences[loc1.fileIndex].tokens;

        for (var j = i + 1; j < locations.length; j++) {
          final loc2 = locations[j];
          final tokens2 = fileSequences[loc2.fileIndex].tokens;

          // Prevent self-overlapping matches within the same file
          if (loc1.fileIndex == loc2.fileIndex &&
              (loc1.tokenIndex - loc2.tokenIndex).abs() < k) {
            continue;
          }

          // Verify token equality for the k-gram seed
          var seedMatches = true;
          for (var m = 0; m < k; m++) {
            if (tokens1[loc1.tokenIndex + m].normalizedLexeme !=
                tokens2[loc2.tokenIndex + m].normalizedLexeme) {
              seedMatches = false;
              break;
            }
          }
          if (!seedMatches) continue;

          // Maximal backward extension
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

          // Maximal forward extension
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

          if (span1.tokenCount < minTokens) continue;

          final lineCount1 =
              tokens1[end1].endLine - tokens1[start1].startLine + 1;
          final lineCount2 =
              tokens2[end2].endLine - tokens2[start2].startLine + 1;
          if (lineCount1 < minLines || lineCount2 < minLines) continue;

          rawPairs.add(_MatchPair(span1, span2));
        }
      }
    }

    if (rawPairs.isEmpty) return const [];

    // 3. Remove subsumed match pairs
    rawPairs.sort((a, b) => b.span1.tokenCount.compareTo(a.span1.tokenCount));
    final nonSubsumedPairs = <_MatchPair>[];

    for (final pair in rawPairs) {
      var isSubsumed = false;
      for (final existing in nonSubsumedPairs) {
        if (pair.isSubsumedBy(existing)) {
          isSubsumed = true;
          break;
        }
      }
      if (!isSubsumed) {
        nonSubsumedPairs.add(pair);
      }
    }

    // 4. Cluster spans via Disjoint Set Union (DSU) / Graph Connected Components
    final spanNodes = <_TokenSpan>[];
    final parent = <int, int>{};

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

    int getOrAddSpanNode(_TokenSpan span) {
      for (var idx = 0; idx < spanNodes.length; idx++) {
        if (spanNodes[idx] == span) return idx;
      }
      final newIdx = spanNodes.length;
      spanNodes.add(span);
      parent[newIdx] = newIdx;
      return newIdx;
    }

    for (final pair in nonSubsumedPairs) {
      final idx1 = getOrAddSpanNode(pair.span1);
      final idx2 = getOrAddSpanNode(pair.span2);
      union(idx1, idx2);
    }

    // Group spans by DSU root
    final clusterMap = <int, List<_TokenSpan>>{};
    for (var i = 0; i < spanNodes.length; i++) {
      final root = find(i);
      clusterMap.putIfAbsent(root, () => []).add(spanNodes[i]);
    }

    // 5. Build DuplicateCluster objects
    final clusters = <DuplicateCluster>[];
    var clusterIndex = 1;

    for (final spans in clusterMap.values) {
      if (spans.length < 2) continue;

      // Deduplicate overlapping spans within the same file in the cluster
      final dedupedSpans = <_TokenSpan>[];
      for (final s in spans) {
        final overlapsExisting = dedupedSpans.any(
          (existing) => existing.overlaps(s),
        );
        if (!overlapsExisting) {
          dedupedSpans.add(s);
        }
      }

      if (dedupedSpans.length < 2) continue;

      final instances = <CloneInstance>[];
      var isIdentical = true;
      var isStructural = true;

      for (final span in dedupedSpans) {
        final seq = fileSequences[span.fileIndex];
        final startToken = seq.tokens[span.startTokenIndex];
        final endToken = seq.tokens[span.endTokenIndex];

        final startLine = startToken.startLine;
        final endLine = endToken.endLine;
        final lineCount = endLine - startLine + 1;
        final snippet = seq.getSnippetForTokens(
          span.startTokenIndex,
          span.endTokenIndex,
        );

        instances.add(
          CloneInstance(
            filePath: seq.filePath,
            startLine: startLine,
            endLine: endLine,
            startColumn: startToken.startColumn,
            endColumn: endToken.endColumn,
            tokenCount: span.tokenCount,
            lineCount: lineCount,
            snippet: snippet,
          ),
        );
      }

      // Check clone bucket across all instances
      final firstSeq = fileSequences[dedupedSpans.first.fileIndex];
      final firstTokens = firstSeq.tokens;
      final firstStart = dedupedSpans.first.startTokenIndex;

      for (var sIdx = 1; sIdx < dedupedSpans.length; sIdx++) {
        final otherSeq = fileSequences[dedupedSpans[sIdx].fileIndex];
        final otherTokens = otherSeq.tokens;
        final otherStart = dedupedSpans[sIdx].startTokenIndex;

        for (var t = 0; t < dedupedSpans.first.tokenCount; t++) {
          final tok1 = firstTokens[firstStart + t];
          final tok2 = otherTokens[otherStart + t];

          if (tok1.originalLexeme != tok2.originalLexeme) {
            isIdentical = false;
          }
          if (tok1.normalizedLexeme == '<ID>' &&
              tok2.normalizedLexeme == '<ID>') {
            if (tok1.originalLexeme != tok2.originalLexeme) {
              isStructural = false;
            }
          }
        }
      }

      final bucket = isIdentical
          ? CloneBucket.identical
          : (isStructural ? CloneBucket.structural : CloneBucket.parameterized);

      final representativeTokens = fileSequences[dedupedSpans.first.fileIndex]
          .tokens
          .sublist(
            dedupedSpans.first.startTokenIndex,
            dedupedSpans.first.endTokenIndex + 1,
          );

      final category = _classifyCategory(representativeTokens);
      final avgLineCount =
          (instances.map((i) => i.lineCount).reduce((a, b) => a + b) /
                  instances.length)
              .round();
      final estimatedLinesSaved = (instances.length - 1) * avgLineCount;

      clusters.add(
        DuplicateCluster(
          id: 'cluster-$clusterIndex',
          instances: instances,
          tokenCount: dedupedSpans.first.tokenCount,
          lineCount: avgLineCount,
          category: category,
          bucket: bucket,
          estimatedLinesSaved: estimatedLinesSaved,
        ),
      );
      clusterIndex++;
    }

    // Sort clusters by estimated lines saved descending, then by token count
    // descending.
    clusters.sort((a, b) {
      final comp = b.estimatedLinesSaved.compareTo(a.estimatedLinesSaved);
      if (comp != 0) return comp;
      return b.tokenCount.compareTo(a.tokenCount);
    });

    return clusters;
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
}
