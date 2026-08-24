import 'dart:async';

import 'package:analytica/testing.dart';
import 'package:checks/checks.dart';
import 'package:test/scaffolding.dart';

void main() {
  group('capturePrints', () {
    test('captures synchronous print statements', () async {
      final output = await capturePrints(() {
        print('Hello');
        print('World');
      });

      check(output).equals('Hello\nWorld\n');
    });

    test('returns empty string when nothing is printed', () async {
      final output = await capturePrints(() {});
      check(output).isEmpty();
    });

    test('captures asynchronous print statements', () async {
      final output = await capturePrints(() async {
        print('Async 1');
        await Future<void>.delayed(const Duration(milliseconds: 10));
        print('Async 2');
      });

      check(output).equals('Async 1\nAsync 2\n');
    });
  });
}
