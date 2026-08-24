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

  group('SyncPrintsChecks', () {
    test('verifies synchronous printed output via getter', () {
      check(() {
        print('Line 1');
        print('Line 2');
      }).prints.equals('Line 1\nLine 2\n');
    });

    test('supports string matchers on prints', () {
      check(() {
        print('Warning: Configuration missing');
      }).prints.contains('Configuration missing');
    });
  });

  group('AsyncPrintsChecks', () {
    test('verifies asynchronous printed output via prints method', () async {
      await check(() async {
        print('Async Task Started');
        await Future<void>.delayed(const Duration(milliseconds: 5));
        print('Async Task Finished');
      }).prints((it) => it.contains('Task Finished'));
    });
  });
}
