import 'package:checks/checks.dart';
import 'package:cognitive_complexity/data_flow.dart';
import 'package:test/scaffolding.dart';

void main() {
  group('SignatureSynthesizer', () {
    const synthesizer = SignatureSynthesizer();

    test('Synthesizes void return when no outputs are present', () {
      final sig = synthesizer.synthesize(
        inputs: [
          const VariableUsage(
            name: 'token',
            type: 'String',
            declarationOffset: 0,
            declarationLine: 1,
          ),
        ],
        outputs: [],
        methodName: '_logToken',
      );

      check(sig).equals('void _logToken(String token)');
    });

    test('Synthesizes Future<void> when async with no outputs', () {
      final sig = synthesizer.synthesize(
        inputs: [
          const VariableUsage(
            name: 'token',
            type: 'String',
            declarationOffset: 0,
            declarationLine: 1,
          ),
        ],
        outputs: [],
        methodName: '_sendToken',
        isAsync: true,
      );

      check(sig).equals('Future<void> _sendToken(String token) async');
    });

    test('Synthesizes single return type when 1 output is present', () {
      final sig = synthesizer.synthesize(
        inputs: [
          const VariableUsage(
            name: 'raw',
            type: 'String',
            declarationOffset: 0,
            declarationLine: 1,
          ),
        ],
        outputs: [
          const VariableUsage(
            name: 'parsed',
            type: 'int',
            declarationOffset: 50,
            declarationLine: 3,
          ),
        ],
        methodName: '_parseNumber',
      );

      check(sig).equals('int _parseNumber(String raw)');
    });

    test('Synthesizes Future<T> for single async return type', () {
      final sig = synthesizer.synthesize(
        inputs: [
          const VariableUsage(
            name: 'url',
            type: 'String',
            declarationOffset: 0,
            declarationLine: 1,
          ),
        ],
        outputs: [
          const VariableUsage(
            name: 'data',
            type: 'Map<String, dynamic>',
            declarationOffset: 50,
            declarationLine: 3,
          ),
        ],
        methodName: '_fetch',
        isAsync: true,
      );

      check(
        sig,
      ).equals('Future<Map<String, dynamic>> _fetch(String url) async');
    });

    test('Synthesizes Dart 3 named Record for 2+ output variables', () {
      final sig = synthesizer.synthesize(
        inputs: [
          const VariableUsage(
            name: 'token',
            type: 'String',
            declarationOffset: 0,
            declarationLine: 1,
          ),
          const VariableUsage(
            name: 'retries',
            type: 'int',
            declarationOffset: 10,
            declarationLine: 2,
          ),
        ],
        outputs: [
          const VariableUsage(
            name: 'isAuthenticated',
            type: 'bool',
            isMutated: true,
            declarationOffset: 20,
            declarationLine: 3,
          ),
          const VariableUsage(
            name: 'currentUser',
            type: 'User?',
            declarationOffset: 60,
            declarationLine: 5,
          ),
        ],
        methodName: '_authenticate',
      );

      check(sig).equals(
        '({bool isAuthenticated, User? currentUser}) '
        '_authenticate(String token, int retries)',
      );
    });

    test('Synthesizes Future<Record> for multiple async outputs', () {
      final sig = synthesizer.synthesize(
        inputs: [],
        outputs: [
          const VariableUsage(
            name: 'a',
            type: 'int',
            declarationOffset: 10,
            declarationLine: 2,
          ),
          const VariableUsage(
            name: 'b',
            type: 'String',
            declarationOffset: 20,
            declarationLine: 3,
          ),
        ],
        methodName: '_compute',
        isAsync: true,
      );

      check(sig).equals('Future<({int a, String b})> _compute() async');
    });
    test('Deduplicates record field names that collide after sanitization', () {
      final sig = synthesizer.synthesize(
        inputs: [],
        outputs: [
          const VariableUsage(
            name: '_x',
            type: 'int',
            declarationOffset: 10,
            declarationLine: 2,
          ),
          const VariableUsage(
            name: 'x',
            type: 'String',
            declarationOffset: 20,
            declarationLine: 3,
          ),
        ],
        methodName: '_extracted',
      );

      check(sig).equals('({int x, String x2}) _extracted()');
    });

    test(
      'Deduplicates result fallback when multiple names are only underscores',
      () {
        final sig = synthesizer.synthesize(
          inputs: [],
          outputs: [
            const VariableUsage(
              name: '_',
              type: 'int',
              declarationOffset: 10,
              declarationLine: 2,
            ),
            const VariableUsage(
              name: '__',
              type: 'String',
              declarationOffset: 20,
              declarationLine: 3,
            ),
          ],
          methodName: '_extracted',
        );

        check(sig).equals('({int result, String result2}) _extracted()');
      },
    );

    test(
      'Synthesizes result fallback when record field name is only underscores',
      () {
        final sig = synthesizer.synthesize(
          inputs: [],
          outputs: [
            const VariableUsage(
              name: '_',
              type: 'int',
              declarationOffset: 10,
              declarationLine: 2,
            ),
            const VariableUsage(
              name: 'val',
              type: 'String',
              declarationOffset: 20,
              declarationLine: 3,
            ),
          ],
          methodName: '_fetchEmpty',
        );

        check(sig).equals('({int result, String val}) _fetchEmpty()');
      },
    );
  });
}
