import 'package:analytica/analytica.dart';
import 'package:args/args.dart';
import 'package:checks/checks.dart';
import 'package:test/scaffolding.dart';

void main() {
  group('AnalyticaArgParserExtensions', () {
    test('addSdkPathOption configures option correctly', () {
      final parser = ArgParser()..addSdkPathOption();
      final results = parser.parse(['--sdk-path', '/custom/sdk']);
      check(results['sdk-path']).equals('/custom/sdk');
    });

    test('addFormatOption configures format option with defaults', () {
      final parser = ArgParser()..addFormatOption();
      final defaultResults = parser.parse([]);
      check(defaultResults['format']).equals('markdown');

      final explicitResults = parser.parse(['-f', 'json']);
      check(explicitResults['format']).equals('json');
    });

    test('addHelpFlag and addVersionFlag configure boolean flags', () {
      final parser = ArgParser()
        ..addHelpFlag()
        ..addVersionFlag();

      final results = parser.parse(['-h', '--version']);
      check(results['help'] as bool).isTrue();
      check(results['version'] as bool).isTrue();
    });

    test('addPathFilterOptions configures exclude and ignore-generated', () {
      final parser = ArgParser()..addPathFilterOptions();
      final defaultResults = parser.parse([]);
      final defaultFilter = parsePathFilter(defaultResults);
      check(defaultFilter.ignoreGenerated).isTrue();
      check(defaultFilter.excludePatterns).isEmpty();

      final customResults = parser.parse([
        '--exclude=test/fixtures/**',
        '--exclude=legacy/**,*.gen.dart',
        '--no-ignore-generated',
      ]);
      final customFilter = parsePathFilter(customResults);
      check(customFilter.ignoreGenerated).isFalse();
      check(
        customFilter.excludePatterns,
      ).deepEquals(['test/fixtures/**', 'legacy/**', '*.gen.dart']);
    });
  });

  group('parseLineBounds', () {
    test('parses valid range string', () {
      final (start, end) = parseLineBounds('10-25');
      check(start).equals(10);
      check(end).equals(25);
    });

    test('parses single line range', () {
      final (start, end) = parseLineBounds('42-42');
      check(start).equals(42);
      check(end).equals(42);
    });

    test('throws FormatException on malformed string', () {
      check(() => parseLineBounds('10')).throws<FormatException>();
      check(() => parseLineBounds('10-20-30')).throws<FormatException>();
      check(() => parseLineBounds('0-10')).throws<FormatException>();
      check(() => parseLineBounds('20-10')).throws<FormatException>();
      check(() => parseLineBounds('abc-def')).throws<FormatException>();
    });
  });

  group('parseNonNegativeInt', () {
    test('parses valid positive integer and zero', () {
      check(parseNonNegativeInt('0', 'test')).equals(0);
      check(parseNonNegativeInt('15', 'test')).equals(15);
    });

    test('throws FormatException on negative or non-integer', () {
      check(() => parseNonNegativeInt('-1', 'test')).throws<FormatException>();
      check(() => parseNonNegativeInt('abc', 'test')).throws<FormatException>();
    });
  });

  group('resolveTargetFileAndLines', () {
    test('resolves file without line specifier', () {
      final result = resolveTargetFileAndLines('lib/src/main.dart');
      check(result.filePath).equals('lib/src/main.dart');
      check(result.linesString).isNull();
    });

    test('resolves file with embedded line bounds', () {
      final result = resolveTargetFileAndLines('lib/src/main.dart:45-80');
      check(result.filePath).equals('lib/src/main.dart');
      check(result.linesString).equals('45-80');
    });

    test('resolves file with explicit lines option', () {
      final result = resolveTargetFileAndLines(
        'lib/src/main.dart',
        explicitLines: '20-30',
      );
      check(result.filePath).equals('lib/src/main.dart');
      check(result.linesString).equals('20-30');
    });

    test('throws FormatException if lines are specified both ways', () {
      check(
        () => resolveTargetFileAndLines(
          'lib/src/main.dart:10-20',
          explicitLines: '30-40',
        ),
      ).throws<FormatException>();
    });
  });

  group('parseCommaSeparated', () {
    test('returns empty list on null, empty string, or whitespace', () {
      check(parseCommaSeparated(null)).isEmpty();
      check(parseCommaSeparated('')).isEmpty();
      check(parseCommaSeparated('   ')).isEmpty();
    });

    test('parses and trims comma-separated tokens', () {
      final items = parseCommaSeparated('foo, bar,baz , qux');
      check(items).deepEquals(['foo', 'bar', 'baz', 'qux']);
    });

    test('skips empty tokens from multiple commas', () {
      final items = parseCommaSeparated('foo,,bar,  ,baz');
      check(items).deepEquals(['foo', 'bar', 'baz']);
    });
  });
}
