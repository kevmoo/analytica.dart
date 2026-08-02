import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';

/// An AST visitor that calculates Cognitive Complexity algorithmically.
///
/// Follows standard Cognitive Complexity rules:
/// - Rule 1 (+0 Penalty): Null-aware operators and switch labels cost +0.
/// - Rule 2 (+1 Base): Flow interruptions (`if`, `for`, `while`, `catch`,
///   logical operators, and pattern `when` guards). Exhaustive `switch` blocks
///   cost a flat +1 base regardless of arm count.
/// - Rule 3 (+D Depth): Nesting multiplier added to base cost for nested flow.
///   Exceptions: `else`, `else if`, and `catch` get flat +1 without depth.
class CognitiveComplexityVisitor extends RecursiveAstVisitor<void> {
  int _score = 0;
  int _depth = 0;

  /// Returns the accumulated cognitive complexity score.
  int get score => _score;

  void _addScore(int value) {
    _score += value;
  }

  void _withIncrementedDepth(void Function() f) {
    _depth++;
    f();
    _depth--;
  }

  @override
  void visitIfStatement(IfStatement node) {
    var isElseIf = false;
    final parent = node.parent;
    if (parent is IfStatement) {
      isElseIf = parent.elseStatement == node;
    }

    if (isElseIf) {
      _addScore(1);
    } else {
      _addScore(1 + _depth);
    }

    node.expression.accept(this);
    node.caseClause?.accept(this);

    _withIncrementedDepth(() {
      node.thenStatement.accept(this);
    });

    final elseStmt = node.elseStatement;
    if (elseStmt != null) {
      if (elseStmt is IfStatement) {
        _withIncrementedDepth(() {
          elseStmt.accept(this);
        });
      } else {
        _addScore(1);
        _withIncrementedDepth(() {
          elseStmt.accept(this);
        });
      }
    }
  }

  @override
  void visitIfElement(IfElement node) {
    var isElseIf = false;
    final parent = node.parent;
    if (parent is IfElement) {
      isElseIf = parent.elseElement == node;
    }

    if (isElseIf) {
      _addScore(1);
    } else {
      _addScore(1 + _depth);
    }

    node.expression.accept(this);
    node.caseClause?.accept(this);

    _withIncrementedDepth(() {
      node.thenElement.accept(this);
    });

    final elseEl = node.elseElement;
    if (elseEl != null) {
      if (elseEl is IfElement) {
        _withIncrementedDepth(() {
          elseEl.accept(this);
        });
      } else {
        _addScore(1);
        _withIncrementedDepth(() {
          elseEl.accept(this);
        });
      }
    }
  }

  @override
  void visitForStatement(ForStatement node) {
    _addScore(1 + _depth);
    node.forLoopParts.accept(this);
    _withIncrementedDepth(() {
      node.body.accept(this);
    });
  }

  @override
  void visitForElement(ForElement node) {
    _addScore(1 + _depth);
    node.forLoopParts.accept(this);
    _withIncrementedDepth(() {
      node.body.accept(this);
    });
  }

  @override
  void visitWhileStatement(WhileStatement node) {
    _addScore(1 + _depth);
    node.condition.accept(this);
    _withIncrementedDepth(() {
      node.body.accept(this);
    });
  }

  @override
  void visitDoStatement(DoStatement node) {
    _addScore(1 + _depth);
    node.condition.accept(this);
    _withIncrementedDepth(() {
      node.body.accept(this);
    });
  }

  @override
  void visitSwitchStatement(SwitchStatement node) {
    _addScore(1);
    node.expression.accept(this);
    _withIncrementedDepth(() {
      for (final member in node.members) {
        member.accept(this);
      }
    });
  }

  @override
  void visitSwitchExpression(SwitchExpression node) {
    _addScore(1);
    node.expression.accept(this);
    _withIncrementedDepth(() {
      for (final caseArm in node.cases) {
        caseArm.accept(this);
      }
    });
  }

  @override
  void visitConditionalExpression(ConditionalExpression node) {
    _addScore(1 + _depth);
    node.condition.accept(this);
    _withIncrementedDepth(() {
      node.thenExpression.accept(this);
      node.elseExpression.accept(this);
    });
  }

  @override
  void visitCatchClause(CatchClause node) {
    _addScore(1);
    _withIncrementedDepth(() {
      node.body.accept(this);
    });
  }

  @override
  void visitBreakStatement(BreakStatement node) {
    if (node.label != null) {
      _addScore(1);
    }
    super.visitBreakStatement(node);
  }

  @override
  void visitContinueStatement(ContinueStatement node) {
    if (node.label != null) {
      _addScore(1);
    }
    super.visitContinueStatement(node);
  }

  @override
  void visitWhenClause(WhenClause node) {
    _addScore(1);
    super.visitWhenClause(node);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    if (node.parent is! CompilationUnit) {
      _addScore(1);
    }
    super.visitFunctionDeclaration(node);
  }

  @override
  void visitFunctionExpression(FunctionExpression node) {
    node.parameters?.accept(this);
    _withIncrementedDepth(() {
      node.body.accept(this);
    });
  }

  @override
  void visitBinaryExpression(BinaryExpression node) {
    if (node.operator.type == TokenType.AMPERSAND_AMPERSAND ||
        node.operator.type == TokenType.BAR_BAR) {
      _handleLogicalExpression(node);
    } else {
      super.visitBinaryExpression(node);
    }
  }

  void _handleLogicalExpression(BinaryExpression node) {
    final operators = <TokenType>[];
    _collectLogicalOperators(node, operators);

    if (operators.isEmpty) {
      return;
    }

    _addScore(1);

    var lastOp = operators.first;
    for (var i = 1; i < operators.length; i++) {
      if (operators[i] != lastOp) {
        _addScore(1);
        lastOp = operators[i];
      }
    }

    _visitNonLogicalOperands(node);
  }

  void _collectLogicalOperators(Expression expr, List<TokenType> operators) {
    final unparenthesized = expr.unParenthesized;
    if (unparenthesized is BinaryExpression) {
      final op = unparenthesized.operator.type;
      if (op == TokenType.AMPERSAND_AMPERSAND || op == TokenType.BAR_BAR) {
        _collectLogicalOperators(unparenthesized.leftOperand, operators);
        operators.add(op);
        _collectLogicalOperators(unparenthesized.rightOperand, operators);
      }
    }
  }

  void _visitNonLogicalOperands(Expression expr) {
    final unparenthesized = expr.unParenthesized;
    if (unparenthesized is BinaryExpression) {
      final op = unparenthesized.operator.type;
      if (op == TokenType.AMPERSAND_AMPERSAND || op == TokenType.BAR_BAR) {
        _visitNonLogicalOperands(unparenthesized.leftOperand);
        _visitNonLogicalOperands(unparenthesized.rightOperand);
        return;
      }
    }
    unparenthesized.accept(this);
  }
}
