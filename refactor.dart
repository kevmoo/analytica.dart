import 'dart:io';

void main() {
  var file = File('lib/src/data_flow/visitors/in_block_visitor.dart');
  var content = file.readAsStringSync();

  // 1. InBlockVisitor._recordUsage -> extract core logic
  content = content.replaceFirst(
    '''  void _recordUsage(Element? element, AstNode node, {required bool isWrite}) {
    if (element != null &&
        element is VariableElement &&
        element is! FieldElement &&
        element is! TopLevelVariableElement &&
        _isDeclaredOutsideSlice(element)) {
      final staticType = node.staticType;
      final typeString = staticType?.getDisplayString() ?? '';
      final typeName = staticType != null && !staticType.isDartCoreNull && typeString != 'dynamic'
          ? staticType.getDisplayString()
          : _resolveTypeName(element);

      final declOffset = element.nameOffset;
      final declLine =
          declOffset >= 0 ? lineInfo.getLocation(declOffset).lineNumber : -1;
      final currentLine = lineInfo.getLocation(node.offset).lineNumber;

      if (isWrite) {
        _addClosureEscapeIfRequired(node, currentLine, typeName);

        final existing = inputs[element];
        inputs[element] =
            (existing ??
                    VariableUsage(
                      name: element.name ?? node.name,
                      type: typeName,
                      declarationOffset: declOffset,
                      declarationLine: declLine,
                    ))
                .copyWith(
              isMutated: true,
            );

        mutations[element] = VariableUsage(
          name: element.name ?? node.name,
          type: typeName,
          declarationOffset: declOffset,
          declarationLine: declLine,
          isMutated: true,
        );
      } else {
        inputs.putIfAbsent(
          element,
          () => VariableUsage(
            name: element.name ?? node.name,
            type: typeName,
            declarationOffset: declOffset,
            declarationLine: declLine,
          ),
        );
      }
    }
  }''',
    '''  void _recordUsage(Element? element, AstNode node, {required bool isWrite}) {
    if (element != null &&
        element is VariableElement &&
        element is! FieldElement &&
        element is! TopLevelVariableElement &&
        _isDeclaredOutsideSlice(element)) {
      _processValidUsage(element, node, isWrite);
    }
  }

  void _processValidUsage(VariableElement element, AstNode node, bool isWrite) {
    final staticType = node.staticType;
    final typeString = staticType?.getDisplayString() ?? '';
    final typeName = staticType != null && !staticType.isDartCoreNull && typeString != 'dynamic'
        ? staticType.getDisplayString()
        : _resolveTypeName(element);

    final declOffset = element.nameOffset;
    final declLine =
        declOffset >= 0 ? lineInfo.getLocation(declOffset).lineNumber : -1;
    final currentLine = lineInfo.getLocation(node.offset).lineNumber;

    if (isWrite) {
      _addClosureEscapeIfRequired(node, currentLine, typeName);

      final existing = inputs[element];
      inputs[element] =
          (existing ??
                  VariableUsage(
                    name: element.name ?? node.name,
                    type: typeName,
                    declarationOffset: declOffset,
                    declarationLine: declLine,
                  ))
              .copyWith(
            isMutated: true,
          );

      mutations[element] = VariableUsage(
        name: element.name ?? node.name,
        type: typeName,
        declarationOffset: declOffset,
        declarationLine: declLine,
        isMutated: true,
      );
    } else {
      inputs.putIfAbsent(
        element,
        () => VariableUsage(
          name: element.name ?? node.name,
          type: typeName,
          declarationOffset: declOffset,
          declarationLine: declLine,
        ),
      );
    }
  }''',
  );

  // 2. InBlockVisitor.visitBreakStatement
  content = content.replaceFirst(
    '''  @override
  // ignore: cognitive_complexity
  void visitBreakStatement(BreakStatement node) {
    if (_isWithinSlice(node)) {
      if (node.label != null) {
        final labelType = node.label.runtimeType.toString();
        final dynLabel = node.label;
        final lName = _extractName(dynLabel);

        final targetOffset = _resolveLabelTargetOffset(node, lName);
        if (targetOffset != null &&
            (targetOffset < sliceStartOffset ||
                targetOffset > sliceEndOffset)) {
          escapes.add(
            ControlFlowEscape(
              type: ControlFlowEscapeType.loopBreak,
              line: lineInfo.getLocation(node.offset).lineNumber,
              description:
                  'Labeled break references loop outside the extracted slice',
            ),
          );
        }
      } else {
        if (!_isEnclosedByBreakableWithinSlice(node)) {
          escapes.add(
            ControlFlowEscape(
              type: ControlFlowEscapeType.loopBreak,
              line: lineInfo.getLocation(node.offset).lineNumber,
              description: 'Break statement alters loop outside extracted slice',
            ),
          );
        }
      }
    }
    super.visitBreakStatement(node);
  }''',
    '''  @override
  void visitBreakStatement(BreakStatement node) {
    if (_isWithinSlice(node)) {
      _processBreak(node);
    }
    super.visitBreakStatement(node);
  }

  void _processBreak(BreakStatement node) {
    if (node.label != null) {
      final dynLabel = node.label;
      final lName = _extractName(dynLabel);
      final targetOffset = _resolveLabelTargetOffset(node, lName);
      if (targetOffset != null &&
          (targetOffset < sliceStartOffset ||
              targetOffset > sliceEndOffset)) {
        escapes.add(
          ControlFlowEscape(
            type: ControlFlowEscapeType.loopBreak,
            line: lineInfo.getLocation(node.offset).lineNumber,
            description:
                'Labeled break references loop outside the extracted slice',
          ),
        );
      }
    } else {
      if (!_isEnclosedByBreakableWithinSlice(node)) {
        escapes.add(
          ControlFlowEscape(
            type: ControlFlowEscapeType.loopBreak,
            line: lineInfo.getLocation(node.offset).lineNumber,
            description: 'Break statement alters loop outside extracted slice',
          ),
        );
      }
    }
  }''',
  );

  // 3. InBlockVisitor.visitContinueStatement
  content = content.replaceFirst(
    '''  @override
  // ignore: cognitive_complexity
  void visitContinueStatement(ContinueStatement node) {
    if (_isWithinSlice(node)) {
      if (node.label != null) {
        final labelType = node.label.runtimeType.toString();
        final dynLabel = node.label;
        final lName = _extractName(dynLabel);

        final targetOffset = _resolveLabelTargetOffset(node, lName);
        if (targetOffset != null &&
            (targetOffset < sliceStartOffset ||
                targetOffset > sliceEndOffset)) {
          escapes.add(
            ControlFlowEscape(
              type: ControlFlowEscapeType.loopContinue,
              line: lineInfo.getLocation(node.offset).lineNumber,
              description:
                  'Labeled continue references loop outside the extracted slice',
            ),
          );
        }
      } else {
        if (!_isEnclosedByBreakableWithinSlice(node)) {
          escapes.add(
            ControlFlowEscape(
              type: ControlFlowEscapeType.loopContinue,
              line: lineInfo.getLocation(node.offset).lineNumber,
              description:
                  'Continue statement alters loop outside extracted slice',
            ),
          );
        }
      }
    }
    super.visitContinueStatement(node);
  }''',
    '''  @override
  void visitContinueStatement(ContinueStatement node) {
    if (_isWithinSlice(node)) {
      _processContinue(node);
    }
    super.visitContinueStatement(node);
  }

  void _processContinue(ContinueStatement node) {
    if (node.label != null) {
      final dynLabel = node.label;
      final lName = _extractName(dynLabel);
      final targetOffset = _resolveLabelTargetOffset(node, lName);
      if (targetOffset != null &&
          (targetOffset < sliceStartOffset ||
              targetOffset > sliceEndOffset)) {
        escapes.add(
          ControlFlowEscape(
            type: ControlFlowEscapeType.loopContinue,
            line: lineInfo.getLocation(node.offset).lineNumber,
            description:
                'Labeled continue references loop outside the extracted slice',
          ),
        );
      }
    } else {
      if (!_isEnclosedByBreakableWithinSlice(node)) {
        escapes.add(
          ControlFlowEscape(
            type: ControlFlowEscapeType.loopContinue,
            line: lineInfo.getLocation(node.offset).lineNumber,
            description:
                'Continue statement alters loop outside extracted slice',
          ),
        );
      }
    }
  }''',
  );

  file.writeAsStringSync(content);

  var file2 = File('lib/src/data_flow/signature_synthesizer.dart');
  var content2 = file2.readAsStringSync();
  content2 = content2.replaceFirst(
    '''  // ignore: cognitive_complexity
  String synthesize({
    required List<VariableUsage> inputs,
    required List<VariableUsage> outputs,
    List<String> typeParameters = const [],
    String methodName = '_extracted',
    bool isAsync = false,
  }) {
    final returnType = _buildReturnType(outputs, isAsync: isAsync);
    final params = _buildParameters(inputs);
    final asyncSuffix = isAsync ? ' async' : '';
    final typeParamsStr = typeParameters.isNotEmpty ? '<\${typeParameters.join(', ')}>' : '';

    return '\$returnType \$methodName\$typeParamsStr(\$params)\$asyncSuffix';
  }''',
    '''  String synthesize({
    required List<VariableUsage> inputs,
    required List<VariableUsage> outputs,
    List<String> typeParameters = const [],
    String methodName = '_extracted',
    bool isAsync = false,
  }) {
    final returnType = _buildReturnType(outputs, isAsync: isAsync);
    final params = _buildParameters(inputs);
    final asyncSuffix = isAsync ? ' async' : '';
    final typeParamsStr = _buildTypeParamsStr(typeParameters);

    return '\$returnType \$methodName\$typeParamsStr(\$params)\$asyncSuffix';
  }

  String _buildTypeParamsStr(List<String> typeParameters) {
    return typeParameters.isNotEmpty ? '<\${typeParameters.join(', ')}>' : '';
  }''',
  );
  file2.writeAsStringSync(content2);
}
