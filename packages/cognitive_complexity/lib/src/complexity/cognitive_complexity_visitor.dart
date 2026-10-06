import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';

/// Breakdown of a Cognitive Complexity score.
///
/// - `branches`: flat `+1` increments (`if`, loops, `switch`, `catch`, `?:`,
///   `else`, labeled jumps, `when` guards).
/// - `nesting`: the summed nesting penalties paid by structural increments.
/// - `booleanOps`: increments from sequences of `&&` / `||`.
/// - `maxDepth`: the deepest nesting level at which a structural increment
///   scored (`1` for a flat function; `0` when nothing scored).
///
/// `branches + nesting + booleanOps` equals the reported score.
typedef ComplexityComposition = ({
  int branches,
  int nesting,
  int booleanOps,
  int maxDepth,
});

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
  int _branches = 0;
  int _nesting = 0;
  int _booleanOps = 0;
  int _maxDepth = 0;
  int _depth;

  /// Creates a [CognitiveComplexityVisitor] starting at [initialDepth].
  CognitiveComplexityVisitor({int initialDepth = 0}) : _depth = initialDepth;

  /// Returns the accumulated cognitive complexity score.
  int get score => _branches + _nesting + _booleanOps;

  /// How [score] decomposes: flat increments, nesting penalties, boolean
  /// operator sequences, and the deepest nesting level that scored.
  ///
  /// `branches + nesting + booleanOps == score` always holds.
  ComplexityComposition get composition => (
    branches: _branches,
    nesting: _nesting,
    booleanOps: _booleanOps,
    maxDepth: _maxDepth,
  );

  /// Structural increment: +1 plus the current nesting depth.
  void _addStructural() {
    _branches += 1;
    _nesting += _depth;
    if (_depth + 1 > _maxDepth) _maxDepth = _depth + 1;
  }

  /// Hybrid or fundamental increment: flat +1, no nesting penalty.
  void _addFlat() {
    _branches += 1;
  }

  void _addBooleanOp() {
    _booleanOps += 1;
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
      _addFlat();
    } else {
      _addStructural();
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
        _addFlat();
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
      _addFlat();
    } else {
      _addStructural();
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
        _addFlat();
        _withIncrementedDepth(() {
          elseEl.accept(this);
        });
      }
    }
  }

  @override
  void visitForStatement(ForStatement node) {
    _addStructural();
    node.forLoopParts.accept(this);
    _withIncrementedDepth(() {
      node.body.accept(this);
    });
  }

  @override
  void visitForElement(ForElement node) {
    _addStructural();
    node.forLoopParts.accept(this);
    _withIncrementedDepth(() {
      node.body.accept(this);
    });
  }

  @override
  void visitWhileStatement(WhileStatement node) {
    _addStructural();
    node.condition.accept(this);
    _withIncrementedDepth(() {
      node.body.accept(this);
    });
  }

  @override
  void visitDoStatement(DoStatement node) {
    _addStructural();
    node.condition.accept(this);
    _withIncrementedDepth(() {
      node.body.accept(this);
    });
  }

  @override
  void visitSwitchStatement(SwitchStatement node) {
    _addStructural();
    node.expression.accept(this);
    _withIncrementedDepth(() {
      for (final member in node.members) {
        member.accept(this);
      }
    });
  }

  @override
  void visitSwitchExpression(SwitchExpression node) {
    _addStructural();
    node.expression.accept(this);
    _withIncrementedDepth(() {
      for (final caseArm in node.cases) {
        caseArm.accept(this);
      }
    });
  }

  @override
  void visitConditionalExpression(ConditionalExpression node) {
    _addStructural();
    node.condition.accept(this);
    _withIncrementedDepth(() {
      node.thenExpression.accept(this);
      node.elseExpression.accept(this);
    });
  }

  @override
  void visitCatchClause(CatchClause node) {
    _addStructural();
    _withIncrementedDepth(() {
      node.body.accept(this);
    });
  }

  @override
  void visitBreakStatement(BreakStatement node) {
    if (node.label != null) {
      _addFlat();
    }
    super.visitBreakStatement(node);
  }

  @override
  void visitContinueStatement(ContinueStatement node) {
    if (node.label != null) {
      _addFlat();
    }
    super.visitContinueStatement(node);
  }

  @override
  void visitWhenClause(WhenClause node) {
    _addFlat();
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

    _addBooleanOp();

    var lastOp = operators.first;
    for (var i = 1; i < operators.length; i++) {
      if (operators[i] != lastOp) {
        _addBooleanOp();
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

/// Computes the Cognitive Complexity score of [parts] starting at
/// [initialDepth].
int scoreAstParts(Iterable<AstNode?> parts, {int initialDepth = 0}) {
  final visitor = CognitiveComplexityVisitor(initialDepth: initialDepth);
  visitor.visitAll(parts);
  return visitor.score;
}

/// Computes the Cognitive Complexity nesting depth of [node] relative to
/// [enclosingDeclaration].
int nestingDepthAt(AstNode node, AstNode enclosingDeclaration) {
  var depth = 0;
  AstNode? current = node;
  while (current != null && !identical(current, enclosingDeclaration)) {
    final parent = current.parent;
    if (parent == null) break;
    final increments = switch (parent) {
      IfStatement(:final thenStatement, :final elseStatement) =>
        identical(current, thenStatement) ||
            (identical(current, elseStatement) && current is! IfStatement),
      IfElement(:final thenElement, :final elseElement) =>
        identical(current, thenElement) ||
            (identical(current, elseElement) && current is! IfElement),
      ForStatement(:final body) ||
      WhileStatement(:final body) ||
      DoStatement(:final body) => identical(current, body),
      ForElement(:final body) => identical(current, body),
      CatchClause(:final body) => identical(current, body),
      SwitchStatement(:final members) => members.contains(current),
      SwitchExpression(:final cases) => cases.contains(current),
      ConditionalExpression(:final thenExpression, :final elseExpression) =>
        identical(current, thenExpression) ||
            identical(current, elseExpression),
      FunctionExpression(:final body) =>
        identical(current, body) &&
            !identical(parent.parent, enclosingDeclaration),
      _ => false,
    };
    if (increments) depth++;
    current = parent;
  }
  return depth;
}
