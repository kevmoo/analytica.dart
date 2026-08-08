import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';

/// An AST visitor that calculates Cognitive Complexity following the
/// SonarSource whitepaper specification (G. Ann Campbell, v1.7).
///
/// - Structural increments (+1 plus the current nesting depth): `if`, the
///   conditional (`?:`) operator, `switch` statements and expressions, `for`
///   (including `for-in` and `await for`), `while`, `do-while`, and `catch`.
///   Each also increases the nesting depth for its contents.
/// - Hybrid increments (flat +1, no nesting penalty): `else` and `else if`.
///   An `else if` chain does not deepen nesting: contents of every branch in
///   the chain sit one level below the head `if`.
/// - Fundamental increments (flat +1): each sequence of like logical
///   operators (`&&`/`||`, with +1 for each alternation between them),
///   labeled `break`/`continue`, and pattern `when` guards (a Dart-specific
///   extension of the spec).
/// - Nesting only (+0): lambdas and local function declarations increase
///   depth for their contents but add no increment themselves.
/// - Free (+0): `try`/`finally`, `throw`/`rethrow`, early `return`,
///   unlabeled `break`/`continue`, null-aware operators (`??`, `?.`),
///   `switch` case labels and patterns, and `assert`.
///
/// Known deviation: the whitepaper's "+1 for each method in a recursion
/// cycle" is not implemented (matching SonarSource's own reference
/// implementation, which omits it as well).
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

  /// Accumulates the score of every non-null node in [nodes].
  ///
  /// Useful for scoring a declaration made of several disjoint parts, such
  /// as a constructor's parameter list, initializers, and body.
  void visitAll(Iterable<AstNode?> nodes) {
    for (final node in nodes) {
      node?.accept(this);
    }
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
        // `else if` links are hybrid increments: the chained `if` scores a
        // flat +1 and its branches nest relative to the head `if`, so no
        // extra depth is added here.
        elseStmt.accept(this);
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
        // Hybrid increment: same handling as `else if` statements.
        elseEl.accept(this);
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
    _addScore(1 + _depth);
    node.expression.accept(this);
    _withIncrementedDepth(() {
      for (final member in node.members) {
        member.accept(this);
      }
    });
  }

  @override
  void visitSwitchExpression(SwitchExpression node) {
    _addScore(1 + _depth);
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
    _addScore(1 + _depth);
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
