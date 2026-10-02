import 'dart:io';

import 'package:analytica/analyzer.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:path/path.dart' as p;

import '../complexity/cognitive_complexity_visitor.dart';
import 'models.dart';
import 'signature_synthesizer.dart';
import 'visitors/in_block_visitor.dart';
import 'visitors/post_block_visitor.dart';

/// Main programmatic analyzer that computes reaching definitions, mutations,
/// and live outputs for a code slice using Dart's resolved AST.
class DataFlowAnalyzer {
  final SignatureSynthesizer synthesizer;
  final String? sdkPath;

  const DataFlowAnalyzer({
    this.synthesizer = const SignatureSynthesizer(),
    this.sdkPath,
  });

  /// Analyzes a file on disk by file path and 1-based line bounds.
  Future<DataFlowResult> analyzeFile({
    required String filePath,
    required int startLine,
    required int endLine,
    String methodName = '_extracted',
  }) async {
    final absPath = p.normalize(p.absolute(filePath));
    final file = File(absPath);
    if (!file.existsSync()) {
      throw FileSystemException('Target file does not exist', filePath);
    }

    final helper = AnalysisContextHelper(
      includedPaths: [absPath],
      sdkPath: sdkPath,
    );
    final unitResult = await helper.getRequiredResolvedUnit(absPath);

    final lineInfo = unitResult.lineInfo;
    if (startLine < 1 || endLine < startLine) {
      throw FormatException(
        'Invalid line bounds: startLine ($startLine) must be >= 1 and '
        '<= endLine ($endLine)',
      );
    }

    final totalLines = lineInfo.lineCount;
    if (startLine > totalLines) {
      throw FormatException(
        'Start line $startLine exceeds total file lines ($totalLines)',
      );
    }

    final startOffset = lineInfo.getOffsetOfLine(startLine - 1);
    final endOffset = endLine >= totalLines
        ? unitResult.unit.end
        : lineInfo.getOffsetOfLine(endLine) - 1;

    final locator = _EnclosingDeclarationVisitor(
      startOffset,
      endLine,
      lineInfo,
    );
    unitResult.unit.accept(locator);
    final enclosingNode = locator.enclosing;

    if (enclosingNode == null) {
      throw FormatException(
        'Target line range $startLine-$endLine does not fall entirely within '
        'a single function or method declaration.',
      );
    }

    final enclosingName = switch (enclosingNode) {
      FunctionDeclaration(:final name) ||
      MethodDeclaration(:final name) => name.lexeme,
      ConstructorDeclaration(:final name) => name?.lexeme ?? 'new',
      _ => 'unknown',
    };

    // 1. Traverse within slice for inputs, mutations, escapes, and async
    final inBlockVisitor = InBlockVisitor(
      sliceStartOffset: startOffset,
      sliceEndOffset: endOffset,
      lineInfo: lineInfo,
    );
    enclosingNode.accept(inBlockVisitor);

    // 2. Traverse after slice for liveness analysis (outputs)
    final loopCollector = _EnclosingLoopCollector(startOffset, endOffset);
    enclosingNode.accept(loopCollector);
    final postBlockVisitor = PostBlockVisitor(
      sliceStartOffset: startOffset,
      sliceEndOffset: endOffset,
      lineInfo: lineInfo,
      internalDeclarations: inBlockVisitor.internalDeclarations,
      mutations: inBlockVisitor.mutations,
      enclosingLoopSpans: loopCollector.spans,
    );
    enclosingNode.accept(postBlockVisitor);

    final inputList = inBlockVisitor.inputs.values.toList();
    final mutationList = inBlockVisitor.mutations.values.toList();
    final outputList = postBlockVisitor.liveOutputs.values.toList();
    final escapes = inBlockVisitor.escapes;

    final typeParams = _extractTypeParams(enclosingNode, inputList, outputList);

    final signature = synthesizer.synthesize(
      inputs: inputList,
      outputs: outputList,
      typeParameters: typeParams,
      methodName: methodName,
      isAsync: inBlockVisitor.hasAwait,
    );

    final (:enclosingScore, :sliceScoreInPlace, :sliceScoreAtRoot) =
        _computeComplexityImpact(enclosingNode, startOffset, endOffset);
    final warnings = _buildExtractionWarnings(
      inputCount: inputList.length,
      sliceLineCount: endLine - startLine + 1,
      enclosingScore: enclosingScore,
      sliceScoreInPlace: sliceScoreInPlace,
    );

    return DataFlowResult(
      filePath: filePath,
      startLine: startLine,
      endLine: endLine,
      enclosingDeclaration: enclosingName,
      inputs: inputList,
      mutations: mutationList,
      outputs: outputList,
      escapes: escapes,
      suggestedSignature: signature,
      isCleanlyExtractable: escapes.isEmpty,
      enclosingScore: enclosingScore,
      sliceScoreInPlace: sliceScoreInPlace,
      sliceScoreAtRoot: sliceScoreAtRoot,
      extractionWarnings: warnings,
    );
  }

  /// In-memory analysis for unit testing and IDE integration.
  Future<DataFlowResult> analyzeSource({
    required String sourceCode,
    required int startLine,
    required int endLine,
    String methodName = '_extracted',
  }) async {
    final tempDir = await Directory.systemTemp.createTemp('data_flow_test_');
    try {
      final tempFile = File(p.join(tempDir.path, 'snippet.dart'));
      await tempFile.writeAsString(sourceCode);

      final result = await analyzeFile(
        filePath: tempFile.path,
        startLine: startLine,
        endLine: endLine,
        methodName: methodName,
      );

      return DataFlowResult(
        filePath: 'snippet.dart',
        startLine: result.startLine,
        endLine: result.endLine,
        enclosingDeclaration: result.enclosingDeclaration,
        inputs: result.inputs,
        mutations: result.mutations,
        outputs: result.outputs,
        escapes: result.escapes,
        suggestedSignature: result.suggestedSignature,
        isCleanlyExtractable: result.isCleanlyExtractable,
        enclosingScore: result.enclosingScore,
        sliceScoreInPlace: result.sliceScoreInPlace,
        sliceScoreAtRoot: result.sliceScoreAtRoot,
        extractionWarnings: result.extractionWarnings,
      );
    } finally {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    }
  }

  ({int enclosingScore, int sliceScoreInPlace, int sliceScoreAtRoot})
  _computeComplexityImpact(
    AstNode enclosingNode,
    int startOffset,
    int endOffset,
  ) {
    final parts = switch (enclosingNode) {
      FunctionDeclaration(:final functionExpression) => <AstNode?>[
        functionExpression.parameters,
        functionExpression.body,
      ],
      MethodDeclaration(:final parameters, :final body) => <AstNode?>[
        parameters,
        body,
      ],
      ConstructorDeclaration(
        :final parameters,
        :final initializers,
        :final body,
      ) =>
        <AstNode?>[parameters, ...initializers, body],
      _ => <AstNode?>[enclosingNode],
    };
    final enclosingScore = scoreAstParts(parts);
    final sliceCollector = _OutermostSliceNodesCollector(
      startOffset,
      endOffset,
    );
    enclosingNode.accept(sliceCollector);

    var inPlace = 0;
    var atRoot = 0;
    for (final sliceNode in sliceCollector.nodes) {
      final depth = nestingDepthAt(sliceNode, enclosingNode);
      inPlace += scoreAstParts([sliceNode], initialDepth: depth);
      atRoot += scoreAstParts([sliceNode]);
    }
    return (
      enclosingScore: enclosingScore,
      sliceScoreInPlace: inPlace,
      sliceScoreAtRoot: atRoot,
    );
  }

  List<String> _buildExtractionWarnings({
    required int inputCount,
    required int sliceLineCount,
    required int enclosingScore,
    required int sliceScoreInPlace,
  }) {
    final warnings = <String>[];
    if (inputCount >= 5) {
      warnings.add(
        'High parameter count ($inputCount inputs): extracting a '
        '$inputCount-parameter helper creates a shallow pass-through '
        'signature. Prefer keeping the slice inline if enclosing complexity '
        '($enclosingScore) is <= 15, choosing a coarser boundary with <= 4 '
        'inputs, or grouping cohesive state.',
      );
    }
    if (sliceScoreInPlace <= 2 && sliceLineCount <= 6) {
      warnings.add(
        'Low complexity payoff (slice saves $sliceScoreInPlace CC across '
        '$sliceLineCount lines): avoid extracting single-caller micro-helpers '
        'unless reused across multiple call sites.',
      );
    } else if (inputCount >= 4 && sliceScoreInPlace <= 3) {
      warnings.add(
        'Shallow signature-to-complexity ratio ($inputCount inputs for '
        '-$sliceScoreInPlace CC reduction): signature and call-site ceremony '
        'may outweigh the complexity saved.',
      );
    }
    return warnings;
  }

  List<String> _extractTypeParams(
    AstNode enclosingNode,
    List<VariableUsage> inputList,
    List<VariableUsage> outputList,
  ) {
    final typeParams = <String>[];
    TypeParameterList? tpl;
    if (enclosingNode is FunctionDeclaration) {
      tpl = enclosingNode.functionExpression.typeParameters;
    } else if (enclosingNode is MethodDeclaration) {
      tpl = enclosingNode.typeParameters;
    }
    if (tpl != null) {
      for (final typeParam in tpl.typeParameters) {
        final tpName = typeParam.name.lexeme;
        final regex = RegExp('\\b${RegExp.escape(tpName)}\\b');
        final isReferenced =
            inputList.any((i) => regex.hasMatch(i.type)) ||
            outputList.any((o) => regex.hasMatch(o.type));
        if (isReferenced) {
          typeParams.add(typeParam.toSource());
        }
      }
    }
    return typeParams;
  }
}

class _OutermostSliceNodesCollector extends UnifyingAstVisitor<void> {
  final int startOffset;
  final int endOffset;
  final List<AstNode> nodes = [];

  _OutermostSliceNodesCollector(this.startOffset, this.endOffset);

  @override
  void visitNode(AstNode node) {
    if (node.offset >= startOffset && node.end <= endOffset) {
      nodes.add(node);
      return;
    }
    if (node.end < startOffset || node.offset > endOffset) {
      return;
    }
    super.visitNode(node);
  }
}

/// Collects the source spans of loops that strictly enclose the slice; loops
/// contained in (or identical to) the slice have their back edge extracted
/// along with it and carry no liveness outside the slice.
class _EnclosingLoopCollector extends RecursiveAstVisitor<void> {
  final int sliceStartOffset;
  final int sliceEndOffset;
  final List<({int offset, int end, int carryBoundary})> spans = [];

  _EnclosingLoopCollector(this.sliceStartOffset, this.sliceEndOffset);

  void _addIfEnclosing(AstNode node, int carryBoundary) {
    if (node.offset < sliceStartOffset && node.end > sliceEndOffset) {
      spans.add((
        offset: node.offset,
        end: node.end,
        carryBoundary: carryBoundary,
      ));
    }
  }

  @override
  void visitForStatement(ForStatement node) {
    // A C-style header declaration (`for (var i = 0; ...)`) carries its value
    // across iterations via the condition and updaters, so it sits inside the
    // carry boundary. A for-in variable is re-bound from the iterator every
    // iteration and cannot carry a slice write backwards.
    final boundary = node.forLoopParts is ForParts
        ? node.body.offset
        : node.offset;
    _addIfEnclosing(node, boundary);
    super.visitForStatement(node);
  }

  @override
  void visitWhileStatement(WhileStatement node) {
    _addIfEnclosing(node, node.offset);
    super.visitWhileStatement(node);
  }

  @override
  void visitDoStatement(DoStatement node) {
    _addIfEnclosing(node, node.offset);
    super.visitDoStatement(node);
  }
}

class _EnclosingDeclarationVisitor extends RecursiveAstVisitor<void> {
  final int startOffset;
  final int endLine;
  final LineInfo lineInfo;
  AstNode? enclosing;

  _EnclosingDeclarationVisitor(this.startOffset, this.endLine, this.lineInfo);

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    if (node.offset <= startOffset &&
        lineInfo.getLocation(node.end).lineNumber >= endLine) {
      enclosing = node;
    }
    super.visitFunctionDeclaration(node);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    if (node.offset <= startOffset &&
        lineInfo.getLocation(node.end).lineNumber >= endLine) {
      enclosing = node;
    }
    super.visitMethodDeclaration(node);
  }

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    if (node.offset <= startOffset &&
        lineInfo.getLocation(node.end).lineNumber >= endLine) {
      enclosing = node;
    }
    super.visitConstructorDeclaration(node);
  }
}
