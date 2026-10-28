import 'package:analytica/analyzer.dart';
import 'package:checks/checks.dart';
import 'package:test/test.dart';

void main() {
  group('WildcardPattern', () {
    test('exact match without wildcards', () {
      final pattern = WildcardPattern('FooBar');
      check(pattern.matches('FooBar')).isTrue();
      check(pattern.matches('Foo')).isFalse();
      check(pattern.matches('FooBarBaz')).isFalse();
      check(pattern.matches('fooBar')).isFalse();
      check(pattern.matches('')).isFalse();
    });

    test('empty pattern matches only empty string', () {
      final pattern = WildcardPattern('');
      check(pattern.matches('')).isTrue();
      check(pattern.matches('a')).isFalse();
    });

    test('asterisk wildcard matches any sequence', () {
      final all = WildcardPattern('*');
      check(all.matches('')).isTrue();
      check(all.matches('a')).isTrue();
      check(all.matches('anything')).isTrue();

      final prefix = WildcardPattern('Fake*');
      check(prefix.matches('Fake')).isTrue();
      check(prefix.matches('FakeService')).isTrue();
      check(prefix.matches('Fake123')).isTrue();
      check(prefix.matches('MyFakeService')).isFalse();
      check(prefix.matches('fake')).isFalse();

      final suffix = WildcardPattern('*Mock');
      check(suffix.matches('Mock')).isTrue();
      check(suffix.matches('UserMock')).isTrue();
      check(suffix.matches('MockUser')).isFalse();

      final infix = WildcardPattern('Foo*Bar');
      check(infix.matches('FooBar')).isTrue();
      check(infix.matches('Foo123Bar')).isTrue();
      check(infix.matches('FooXBar')).isTrue();
      check(infix.matches('Foo')).isFalse();
      check(infix.matches('Bar')).isFalse();
      check(infix.matches('FooBarBaz')).isFalse();

      final multi = WildcardPattern('*Fake*');
      check(multi.matches('Fake')).isTrue();
      check(multi.matches('MyFakeService')).isTrue();
      check(multi.matches('FakeService')).isTrue();
      check(multi.matches('MyFake')).isTrue();
      check(multi.matches('NoMatch')).isFalse();
    });

    test('question mark wildcard matches single character', () {
      final single = WildcardPattern('?');
      check(single.matches('a')).isTrue();
      check(single.matches('')).isFalse();
      check(single.matches('ab')).isFalse();

      final prefix = WildcardPattern('Foo?');
      check(prefix.matches('Foo1')).isTrue();
      check(prefix.matches('FooA')).isTrue();
      check(prefix.matches('Foo')).isFalse();
      check(prefix.matches('Foo12')).isFalse();

      final mixed = WildcardPattern('?oo?');
      check(mixed.matches('Fool')).isTrue();
      check(mixed.matches('Food')).isTrue();
      check(mixed.matches('Foo')).isFalse();
      check(mixed.matches('Fooo1')).isFalse();
    });

    test('combined * and ? wildcards', () {
      final pattern = WildcardPattern('Fake*?');
      check(pattern.matches('Fake1')).isTrue();
      check(pattern.matches('FakeServiceA')).isTrue();
      check(pattern.matches('Fake')).isFalse();

      final atLeastOne = WildcardPattern('?*');
      check(atLeastOne.matches('')).isFalse();
      check(atLeastOne.matches('a')).isTrue();
      check(atLeastOne.matches('abc')).isTrue();
    });

    test('escapes special regex characters correctly', () {
      final dotPattern = WildcardPattern('Foo.Bar*');
      check(dotPattern.matches('Foo.Bar')).isTrue();
      check(dotPattern.matches('Foo.BarBaz')).isTrue();
      check(dotPattern.matches('FooXBar')).isFalse();

      final bracketPattern = WildcardPattern('Foo[0]*');
      check(bracketPattern.matches('Foo[0]')).isTrue();
      check(bracketPattern.matches('Foo[0]abc')).isTrue();
      check(bracketPattern.matches('Foo0')).isFalse();

      final plusPattern = WildcardPattern('Foo+Bar');
      check(plusPattern.matches('Foo+Bar')).isTrue();
      check(plusPattern.matches('FooooBar')).isFalse();

      final dollarPattern = WildcardPattern(r'Foo$Bar*');
      check(dollarPattern.matches(r'Foo$Bar')).isTrue();
      check(dollarPattern.matches(r'Foo$Bar123')).isTrue();
      check(dollarPattern.matches('FooBar')).isFalse();

      final parenPattern = WildcardPattern('Foo(Bar)');
      check(parenPattern.matches('Foo(Bar)')).isTrue();
      check(parenPattern.matches('FooBar')).isFalse();
    });

    test('case sensitivity option', () {
      final caseInsensitive = WildcardPattern('fake*', caseSensitive: false);
      check(caseInsensitive.matches('FakeService')).isTrue();
      check(caseInsensitive.matches('fakeService')).isTrue();
      check(caseInsensitive.matches('FAKESERVICE')).isTrue();
      check(caseInsensitive.matches('Other')).isFalse();

      final caseSensitive = WildcardPattern('fake*');
      check(caseSensitive.matches('fakeService')).isTrue();
      check(caseSensitive.matches('FakeService')).isFalse();
    });

    test('anyMatch helper evaluates pattern collections', () {
      final patterns = [WildcardPattern('Fake*'), WildcardPattern('*Mock')];

      check(WildcardPattern.anyMatch(patterns, 'FakeService')).isTrue();
      check(WildcardPattern.anyMatch(patterns, 'UserMock')).isTrue();
      check(WildcardPattern.anyMatch(patterns, 'RealService')).isFalse();

      check(WildcardPattern.anyMatch([], 'FakeService')).isFalse();
    });

    test('equality, hashCode, and toString', () {
      final p1 = WildcardPattern('Fake*');
      final p2 = WildcardPattern('Fake*');
      final p3 = WildcardPattern('Fake*', caseSensitive: false);
      final p4 = WildcardPattern('Mock*');

      check(p1 == p2).isTrue();
      check(p1.hashCode == p2.hashCode).isTrue();
      check(p1 == p3).isFalse();
      check(p1 == p4).isFalse();
      check(p1.toString()).equals('WildcardPattern(Fake*)');
    });

    test('handles consecutive asterisks and regex meta-characters', () {
      final doubleStar = WildcardPattern('**Foo**');
      check(doubleStar.matches('Foo')).isTrue();
      check(doubleStar.matches('prefixFoosuffix')).isTrue();
      check(doubleStar.matches('Bar')).isFalse();

      final metaPattern = WildcardPattern(r'^{test}|[1-9]+$*');
      check(metaPattern.matches(r'^{test}|[1-9]+$')).isTrue();
      check(metaPattern.matches(r'^{test}|[1-9]+$Extra')).isTrue();
      check(metaPattern.matches(r'test')).isFalse();
    });
  });
}
