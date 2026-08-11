# Statement Data-Flow Analysis

The `data_flow` tool and library provide statement-level static data-flow
analysis for Dart codebases. It is designed to evaluate contiguous statement
slices for safe, automated refactoring (such as the Extract Method pattern).

## Analysis Concepts

Given a target Dart source file and contiguous line range (statement slice), the
analyzer evaluates:

- **Inputs**: Variables declared outside the slice that are read inside it
  (preserving static type promotion at read sites).
- **Mutations**: Variables declared outside the slice that are reassigned or
  mutated within the slice.
- **Outputs**: Variables declared or mutated inside the slice that remain live
  and are read downstream.
- **Control Flow Escapes**: Identifies out-of-scope jumps (`return`, labeled
  `break` / `continue`, `yield`, unhandled `rethrow`, and escaping asynchronous
  closure mutations).
- **Synthesized Signature**: Automatically generates an idiomatic Dart 3 Record
  return signature (e.g. `({String name, int count})`) when multiple variables
  are live downstream.

## CLI Usage

The `data_flow` executable is included in the package.

### 1. On-Demand Execution

```bash
# Default JSON output
dart run cognitive_complexity:data_flow@ lib/src/my_file.dart:45-80

# Human-readable terminal report
dart run cognitive_complexity:data_flow@ --format=text lib/src/my_file.dart:45-80
```

### 2. Propose Helper Method Name

Pass `--name` to customize the synthesized helper signature:

```bash
dart run cognitive_complexity:data_flow --name=_processItem lib/src/my_file.dart:45-80
```

### 3. Global Command

If installed globally via `dart install cognitive_complexity`:

```bash
data_flow lib/src/my_file.dart:45-80
```

## Programmatic API

Add `cognitive_complexity` to your dependencies in `pubspec.yaml`:

```yaml
dependencies:
  cognitive_complexity: ^0.2.3
```

### Example

```dart
import 'package:cognitive_complexity/data_flow.dart';

void main() async {
  const analyzer = DataFlowAnalyzer();
  final result = await analyzer.analyzeFile(
    filePath: 'lib/src/service.dart',
    startLine: 45,
    endLine: 80,
    methodName: '_processUser',
  );

  print('Cleanly extractable: ${result.isCleanlyExtractable}');
  print('Inputs: ${result.inputs.map((u) => u.name).join(', ')}');
  print('Outputs: ${result.outputs.map((u) => u.name).join(', ')}');
  print('Proposed Signature: ${result.suggestedSignature}');
}
```
