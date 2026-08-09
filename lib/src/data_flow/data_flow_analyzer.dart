import 'dart:io';
import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:path/path.dart' as p;
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

    final effectiveSdkPath = sdkPath ?? _findSdkPath();
    final collection = AnalysisContextCollection(
      includedPaths: [absPath],
      sdkPath: effectiveSdkPath,
    );
    final context = collection.contextFor(absPath);
    final unitResult = await context.currentSession.getResolvedUnit(absPath);

    if (unitResult is! ResolvedUnitResult || !unitResult.exists) {
      throw StateError('Failed to resolve Dart unit for "$filePath"');
    }

    return _analyzeResolvedUnit(
      unitResult: unitResult,
      filePath: filePath,
      startLine: startLine,
      endLine: endLine,
      methodName: methodName,
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
      );
    } finally {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    }
  }

  DataFlowResult _analyzeResolvedUnit({
    required ResolvedUnitResult unitResult,
    required String filePath,
    required int startLine,
    required int endLine,
    required String methodName,
  }) {
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

    final enclosingName = _getDeclarationName(enclosingNode);

    // 1. Traverse within slice for inputs, mutations, escapes, and async
    final inBlockVisitor = InBlockVisitor(
      sliceStartOffset: startOffset,
      sliceEndOffset: endOffset,
      lineInfo: lineInfo,
    );
    enclosingNode.accept(inBlockVisitor);

    // 2. Traverse after slice for liveness analysis (outputs)
    final postBlockVisitor = PostBlockVisitor(
      sliceStartOffset: startOffset,
      sliceEndOffset: endOffset,
      lineInfo: lineInfo,
      internalDeclarations: inBlockVisitor.internalDeclarations,
      mutations: inBlockVisitor.mutations,
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
    );
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
        final regex = RegExp('\\b$tpName\\b');
        final isReferenced =
            inputList.any((i) => regex.hasMatch(i.type)) ||
            outputList.any((o) => regex.hasMatch(o.type));
        if (isReferenced) {
          typeParams.add(tpName);
        }
      }
    }
    return typeParams;
  }

  String _getDeclarationName(AstNode node) {
    if (node is FunctionDeclaration) {
      return node.name.lexeme;
    }
    if (node is MethodDeclaration) {
      return node.name.lexeme;
    }
    if (node is ConstructorDeclaration) {
      return node.name?.lexeme ?? 'new';
    }
    return 'unknown';
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

// TODO: Replace manual SDK discovery helpers with package:cli_util once
// https://github.com/dart-lang/tools/issues/2504 lands and is published.
String? _findSdkPath() =>
    _findSdkFromExecutable() ?? _findSdkFromEnv() ?? _findSdkFromPath();

String? _findSdkFromExecutable() {
  final exe = File(Platform.resolvedExecutable);
  if (!exe.existsSync()) return null;

  try {
    final resolved = exe.resolveSymbolicLinksSync();
    final candidate = p.dirname(p.dirname(resolved));
    return _isValidSdk(candidate) ? candidate : null;
  } catch (_) {
    return null;
  }
}

String? _findSdkFromEnv() {
  final envSdk = Platform.environment['DART_SDK'];
  if (envSdk != null && _isValidSdk(envSdk)) {
    return envSdk;
  }
  return null;
}

String? _findSdkFromPath() {
  final pathEnv = Platform.environment['PATH'];
  if (pathEnv == null || pathEnv.isEmpty) return null;

  final separator = Platform.isWindows ? ';' : ':';
  final executableName = Platform.isWindows ? 'dart.exe' : 'dart';

  for (final dir in pathEnv.split(separator)) {
    if (dir.trim().isEmpty) continue;
    final candidate = _resolveSdkFromDir(dir, executableName);
    if (candidate != null) return candidate;
  }

  return null;
}

String? _resolveSdkFromDir(String dir, String executableName) {
  final dartBinary = File(p.join(dir, executableName));
  if (!dartBinary.existsSync()) return null;

  try {
    final resolved = dartBinary.resolveSymbolicLinksSync();
    final candidate = p.dirname(p.dirname(resolved));
    return _isValidSdk(candidate) ? candidate : null;
  } catch (_) {
    return null;
  }
}

bool _isValidSdk(String path) {
  final internal = Directory(p.join(path, 'lib', '_internal'));
  if (!internal.existsSync()) return false;
  return File(p.join(internal.path, 'libraries.dart')).existsSync() ||
      File(
        p.join(internal.path, 'sdk_library_metadata', 'lib', 'libraries.dart'),
      ).existsSync() ||
      File(
        p.join(path, 'bin', Platform.isWindows ? 'dart.exe' : 'dart'),
      ).existsSync();
}
