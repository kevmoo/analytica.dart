import 'package:analyzer/dart/ast/ast.dart';

import 'framework_adapter.dart';

/// Adapter for `package:test` test suites, discovering leaf test calls and
/// lifecycle fixtures.
class PackageTestAdapter extends BaseFrameworkAdapter {
  const PackageTestAdapter();

  static const _testFunctionNames = {'test', 'testWidgets', 'solo_test'};

  static const _fixtureFunctionNames = {
    'setUp',
    'setUpAll',
    'tearDown',
    'tearDownAll',
  };

  @override
  bool isTestCallSite(MethodInvocation node) {
    final name = node.methodName.name;
    return _testFunctionNames.contains(name);
  }

  @override
  bool isTestHarnessSite(MethodInvocation node) {
    final name = node.methodName.name;
    return _fixtureFunctionNames.contains(name);
  }
}
