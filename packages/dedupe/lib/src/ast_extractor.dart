import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';

import 'minhash.dart';
import 'tokenizer.dart';

/// Represents a syntactically bounded AST candidate unit for clone detection.
class AstCandidateUnit {
  final String filePath;
  final int fileIndex;
  final int startLine;
  final int endLine;
  final int startOffset;
  final int endOffset;
  final int startTokenIndex;
  final int endTokenIndex;
  final int tokenCount;
  final int lineCount;
  final String astNodeType;
  final int signatureHash;
  final bool isDeclaration;
  final List<int> minHashSignature;
  final Set<int> statementHashes;

  const AstCandidateUnit({
    required this.filePath,
    required this.fileIndex,
    required this.startLine,
    required this.endLine,
    required this.startOffset,
    required this.endOffset,
    required this.startTokenIndex,
    required this.endTokenIndex,
    required this.tokenCount,
    required this.lineCount,
    required this.astNodeType,
    required this.signatureHash,
    this.isDeclaration = false,
    this.minHashSignature = const [],
    this.statementHashes = const {},
  });

  bool contains(AstCandidateUnit other) {
    if (fileIndex != other.fileIndex) return false;
    return startTokenIndex <= other.startTokenIndex &&
        endTokenIndex >= other.endTokenIndex;
  }

  @override
  String toString() =>
      '$astNodeType: $filePath:L$startLine-L$endLine ($tokenCount tokens)';
}

/// Extracts syntactically valid AST candidate units from Dart source files.
class AstExtractor {
  final bool ignoreComments;
  final bool ignoreLiterals;
  final bool ignoreIdentifiers;
  final int minTokens;
  final int minLines;

  static const int _primeBase = 31337;
  static const int _hashMask = 0x7FFFFFFFFFFFFFFF;

  const AstExtractor({
    this.ignoreComments = true,
    this.ignoreLiterals = true,
    this.ignoreIdentifiers = false,
    this.minTokens = 40,
    this.minLines = 4,
  });

  /// Extracts all AST candidate units and the underlying [TokenSequence] for
  /// [filePath] and [content].
  (TokenSequence, List<AstCandidateUnit>) extract({
    required String filePath,
    required String content,
    required int fileIndex,
  }) {
    final tokenMap = <int, int>{};
    final tokenizer = DartTokenizer(
      ignoreComments: ignoreComments,
      ignoreLiterals: ignoreLiterals,
      ignoreIdentifiers: ignoreIdentifiers,
    );

    final sequence = tokenizer.tokenize(
      filePath: filePath,
      content: content,
      tokenOffsetMap: tokenMap,
    );

    final parseResult = parseString(
      content: content,
      path: filePath,
      throwIfDiagnostics: false,
    );

    final candidateVisitor = _DedupeAstVisitor(
      filePath: filePath,
      fileIndex: fileIndex,
      lineInfo: sequence.lineInfo,
      tokens: sequence.tokens,
      tokenMap: tokenMap,
      minTokens: minTokens,
      minLines: minLines,
    );

    parseResult.unit.accept(candidateVisitor);

    return (sequence, candidateVisitor.candidates);
  }
}

class _DedupeAstVisitor extends RecursiveAstVisitor<void> {
  final String filePath;
  final int fileIndex;
  final LineInfo lineInfo;
  final List<NormalizedToken> tokens;
  final Map<int, int> tokenMap;
  final int minTokens;
  final int minLines;
  final MinHasher minHasher = MinHasher();

  final List<AstCandidateUnit> candidates = [];

  _DedupeAstVisitor({
    required this.filePath,
    required this.fileIndex,
    required this.lineInfo,
    required this.tokens,
    required this.tokenMap,
    required this.minTokens,
    required this.minLines,
  });

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    _tryAddCandidate(
      node: node,
      nodeType: 'FunctionDeclaration',
      isDeclaration: true,
      body: node.functionExpression.body,
    );
    super.visitFunctionDeclaration(node);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    _tryAddCandidate(
      node: node,
      nodeType: 'MethodDeclaration',
      isDeclaration: true,
      body: node.body,
    );
    super.visitMethodDeclaration(node);
  }

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    _tryAddCandidate(
      node: node,
      nodeType: 'ConstructorDeclaration',
      isDeclaration: true,
      body: node.body,
    );
    super.visitConstructorDeclaration(node);
  }

  @override
  void visitBlock(Block node) {
    _tryAddCandidate(
      node: node,
      nodeType: 'Block',
      statements: node.statements,
    );
    super.visitBlock(node);
  }

  @override
  void visitIfStatement(IfStatement node) {
    _tryAddCandidate(node: node, nodeType: 'IfStatement');
    super.visitIfStatement(node);
  }

  @override
  void visitForStatement(ForStatement node) {
    _tryAddCandidate(node: node, nodeType: 'ForStatement');
    super.visitForStatement(node);
  }

  @override
  void visitWhileStatement(WhileStatement node) {
    _tryAddCandidate(node: node, nodeType: 'WhileStatement');
    super.visitWhileStatement(node);
  }

  @override
  void visitTryStatement(TryStatement node) {
    _tryAddCandidate(node: node, nodeType: 'TryStatement');
    super.visitTryStatement(node);
  }

  @override
  void visitSwitchStatement(SwitchStatement node) {
    _tryAddCandidate(node: node, nodeType: 'SwitchStatement');
    super.visitSwitchStatement(node);
  }

  void _tryAddCandidate({
    required AstNode node,
    required String nodeType,
    bool isDeclaration = false,
    FunctionBody? body,
    NodeList<Statement>? statements,
  }) {
    final startTokenIdx = tokenMap[node.beginToken.offset];
    final endTokenIdx = tokenMap[node.endToken.offset];

    if (startTokenIdx == null || endTokenIdx == null) return;
    if (startTokenIdx > endTokenIdx) return;

    final tokenCount = endTokenIdx - startTokenIdx + 1;
    if (tokenCount < minTokens) return;

    final startLine = lineInfo.getLocation(node.beginToken.offset).lineNumber;
    final endLine = lineInfo.getLocation(node.endToken.end).lineNumber;
    final lineCount = endLine - startLine + 1;
    if (lineCount < minLines) return;

    final sigHash = _computeSpanHash(startTokenIdx, endTokenIdx);
    final stmtHashes = _extractStatementHashes(
      body: body,
      statements: statements,
    );
    final minHashSig = stmtHashes.length >= 2
        ? minHasher.computeSignature(stmtHashes)
        : const <int>[];

    candidates.add(
      AstCandidateUnit(
        filePath: filePath,
        fileIndex: fileIndex,
        startLine: startLine,
        endLine: endLine,
        startOffset: node.beginToken.offset,
        endOffset: node.endToken.end,
        startTokenIndex: startTokenIdx,
        endTokenIndex: endTokenIdx,
        tokenCount: tokenCount,
        lineCount: lineCount,
        astNodeType: nodeType,
        signatureHash: sigHash,
        isDeclaration: isDeclaration,
        minHashSignature: minHashSig,
        statementHashes: stmtHashes,
      ),
    );
  }

  Set<int> _extractStatementHashes({
    FunctionBody? body,
    NodeList<Statement>? statements,
  }) {
    final hashes = <int>{};
    final stmts =
        statements ??
        (body is BlockFunctionBody ? body.block.statements : null);
    if (stmts == null) return hashes;

    for (final s in stmts) {
      final start = tokenMap[s.beginToken.offset];
      final end = tokenMap[s.endToken.offset];
      if (start != null && end != null && start <= end) {
        hashes.add(_computeSpanHash(start, end));
      }
    }
    return hashes;
  }

  int _computeSpanHash(int startIdx, int endIdx) {
    var hash = 0;
    for (var i = startIdx; i <= endIdx; i++) {
      hash =
          ((hash * AstExtractor._primeBase) + tokens[i].tokenHash) &
          AstExtractor._hashMask;
    }
    return hash;
  }
}
