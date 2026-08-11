# Scoring Model & Specification

Cognitive Complexity measures how difficult a unit of code is for a human
engineer to read, comprehend, and maintain. Unlike Cyclomatic Complexity—which
measures the mathematical density of execution paths and test branch
coverage—Cognitive Complexity penalizes structures that disrupt linear reading
and deeply nested logic.

Scoring follows the [SonarSource Cognitive Complexity whitepaper][whitepaper]
(G. Ann Campbell, v1.7) adapted for modern Dart 3 syntax.

## Scoring Rules & Multipliers

Each construct contributes a **Base Cost** (flat penalty) and may also apply a
**Nesting Multiplier** based on the current nesting depth ($D$).

<!-- mdformat off(prevent table wrapping) -->

| Construct / Syntax                                              | Base Cost |  Nesting Multiplier  | Deepens Nesting? | Notes                                            |
| :-------------------------------------------------------------- | :-------: | :------------------: | :--------------: | :----------------------------------------------- |
| **`if`, `for`, `while`, `do-while`, `catch` / `on`**            |   `+1`    | `+D` (Current Depth) |     **Yes**      | Standard flow-breaking structures                |
| **`switch` Statements & Expressions**                           |   `+1`    | `+D` (Current Depth) |     **Yes**      | Entire block costs `+1` regardless of arm count  |
| **`else` / `else if`**                                          |   `+1`    | `+0` (Flat penalty)  |      **No**      | Branch contents sit one level below head `if`    |
| **Logical Operators (`&&`, `\|\|`)**                            |   `+1`    | `+0` (Flat penalty)  |      **No**      | `+1` per sequence; `+1` for each alternation     |
| **Pattern `when` Guards**                                       |   `+1`    | `+0` (Flat penalty)  |      **No**      | Dart 3 specific interpretation                   |
| **Lambdas & Local Functions**                                   |   `+0`    |         `+0`         |     **Yes**      | Deepens nesting depth for enclosed bodies        |
| **Null-Aware (`??`, `?.`, `??=`), `assert`, `try` / `finally`** |   `+0`    |         `+0`         |      **No**      | Benign syntax; completely free                   |
| **Switch Case Labels & Pattern Combinators**                    |   `+0`    |         `+0`         |      **No**      | Stacked arms / or-patterns (`1 \|\| 2`) are free |

<!-- mdformat on -->

## Dart-Specific Interpretations

1. **Pattern `when` Guards**: Pattern guards (`case Pattern() when condition:`)
   evaluate an additional boolean predicate beyond structural pattern matching.
   Each `when` clause adds `+1` (flat penalty without nesting increment).

2. **Pattern Combinators (`||`, `&&`)**: Pattern-level combinators (such as
   `case 1 || 2:` or `case > 0 && < 10:`) are scored at `+0`. In Dart 3, an
   or-pattern is the idiomatic representation of stacked case labels, which the
   whitepaper scores at zero.

3. **Switch Expressions & Statements**: A `switch` expression or statement adds
   `+1` (plus nesting depth $D$). Individual `case` arms are free, encouraging
   developers to replace cascading `if-else` chains with pattern-matching switch
   expressions.

4. **Recursion Cycles**: The whitepaper suggestion of "+1 for each method in a
   recursion cycle" is omitted, matching SonarSource's reference implementation
   (`sonar-java`).

5. **Collection Control Flow (`if`, `for`)**: Collection literals containing
   `if` or `for` elements are scored identically to their statement
   counterparts.

[whitepaper]: https://www.sonarsource.com/docs/CognitiveComplexity.pdf
