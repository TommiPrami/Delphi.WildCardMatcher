unit Delphi.WildCardMatcher.DUnitX;

interface

uses
  DUnitX.TestFramework,
  Delphi.WildCardMatcher;

type
  [TestFixture]
  TWildCardMatcherDUnitX = class
  public
    { Spec example 1: '*' }
    [Test]
    procedure AsteriskMatchesAnyNumberOfCharsTest;
    [Test]
    procedure AsteriskMatchesEmptyTest;
    [Test]
    procedure AsteriskMustBeAtStartToMatchPrefix_SpecExampleTest;
    [Test]
    procedure LeadingAsteriskMatchesAnywhereTest;
    [Test]
    procedure SurroundingAsterisksMatchSubstringTest;
    [Test]
    procedure ConsecutiveAsterisksCollapseTest;

    { Spec example 2: '?' }
    [Test]
    procedure QuestionMarkMatchesSingleCharTest;
    [Test]
    procedure QuestionMarkRequiresACharacterTest;

    { Spec example 3: '[abc]' }
    [Test]
    procedure CharClassPositiveSetTest;

    { Spec example 4: '[!abc]' }
    [Test]
    procedure CharClassNegatedSetTest;
    [Test]
    procedure NegatedSetAtStartSpecExampleTest;

    { Spec example 5: '[a-c]' }
    [Test]
    procedure CharClassRangeTest;
    [Test]
    procedure CombinedRangesTest;
    [Test]
    procedure NegatedRangeTest;

    { Spec example 6: '#' }
    [Test]
    procedure HashMatchesSingleDigitTest;
    [Test]
    procedure HashRejectsNonDigitTest;

    { Edge cases }
    [Test]
    procedure EmptyPatternMatchesOnlyEmptyInputTest;
    [Test]
    procedure EmptyInputMatchesOnlyEmptyOrAsteriskTest;
    [Test]
    procedure ExactLiteralMatchTest;
    [Test]
    procedure LiteralCaseInsensitiveByDefaultTest;
    [Test]
    procedure CaseSensitiveFlagTest;
    [Test]
    procedure UnterminatedClassReturnsFalseTest;
    [Test]
    procedure EmptyClassReturnsFalseTest;
    [Test]
    procedure LiteralCloseBracketAsFirstClassCharTest;
    [Test]
    procedure DashAsLiteralAtStartOrEndOfClassTest;

    { '|' extension: one-or-more line endings }
    [Test]
    procedure PipeMatchesSingleCrlfTest;
    [Test]
    procedure PipeMatchesSingleLfTest;
    [Test]
    procedure PipeMatchesSingleCrTest;
    [Test]
    procedure PipeMatchesMultipleEolsTest;
    [Test]
    procedure PipeMatchesMixedEolsTest;
    [Test]
    procedure PipeRequiresAtLeastOneEolTest;
    [Test]
    procedure PipeDoesNotMatchEndOfInputTest;
    [Test]
    procedure ConsecutivePipesCollapseTest;
    [Test]
    procedure PipeAtStartAndEndOfPatternTest;
    [Test]
    procedure PipeCombinedWithAsteriskTest;
    [Test]
    procedure PipeStructuralMatchTest;

    { Combinations }
    [Test]
    procedure ComplexFileNameLikePatternsTest;
    [Test]
    procedure MixedSpecialCharsInClassTest;
    [Test]
    procedure ManyAsterisksDoNotExplodeTest;

    { Multi-pattern overloads }
    [Test]
    procedure MatchTArrayReturnsTrueWhenAnyMatchesTest;
    [Test]
    procedure MatchTArrayReturnsFalseWhenNoneMatchTest;
    [Test]
    procedure MatchTArrayEmptyReturnsFalseTest;
    [Test]
    procedure MatchTArrayShortCircuitsOnFirstMatchTest;
    [Test]
    procedure MatchTArrayHonoursCaseSensitiveFlagTest;
    [Test]
    procedure MatchTStringsReturnsTrueWhenAnyMatchesTest;
    [Test]
    procedure MatchTStringsReturnsFalseWhenNoneMatchTest;
    [Test]
    procedure MatchTStringsEmptyReturnsFalseTest;
    [Test]
    procedure MatchTStringsHonoursCaseSensitiveFlagTest;
  end;

implementation

uses
  System.Classes, System.SysUtils;

{ Spec example 1: '*' }

procedure TWildCardMatcherDUnitX.AsteriskMatchesAnyNumberOfCharsTest;
begin
  // wh* finds what, white, why (from the spec)
  Assert.IsTrue(TWildCard.Match('what',  'wh*'));
  Assert.IsTrue(TWildCard.Match('white', 'wh*'));
  Assert.IsTrue(TWildCard.Match('why',   'wh*'));
end;

procedure TWildCardMatcherDUnitX.AsteriskMatchesEmptyTest;
begin
  // '*' must match zero characters as well
  Assert.IsTrue(TWildCard.Match('',    '*'));
  Assert.IsTrue(TWildCard.Match('wh',  'wh*'), '"wh" should match "wh*" (trailing * = zero chars)');
end;

procedure TWildCardMatcherDUnitX.AsteriskMustBeAtStartToMatchPrefix_SpecExampleTest;
begin
  // From the spec: "wh* finds what, white, and why, but not awhile or watch"
  Assert.IsFalse(TWildCard.Match('awhile', 'wh*'), '"awhile" must NOT match "wh*"');
  Assert.IsFalse(TWildCard.Match('watch',  'wh*'), '"watch" must NOT match "wh*"');
end;

procedure TWildCardMatcherDUnitX.LeadingAsteriskMatchesAnywhereTest;
begin
  Assert.IsTrue(TWildCard.Match('readme.txt', '*.txt'));
  Assert.IsTrue(TWildCard.Match('a.txt',      '*.txt'));
  Assert.IsTrue(TWildCard.Match('.txt',       '*.txt'));
  Assert.IsFalse(TWildCard.Match('readme.doc', '*.txt'));
end;

procedure TWildCardMatcherDUnitX.SurroundingAsterisksMatchSubstringTest;
begin
  Assert.IsTrue(TWildCard.Match('hello world',   '*world*'));
  Assert.IsTrue(TWildCard.Match('worldview',     '*world*'));
  Assert.IsTrue(TWildCard.Match('world',         '*world*'));
  Assert.IsFalse(TWildCard.Match('hello',        '*world*'));
end;

procedure TWildCardMatcherDUnitX.ConsecutiveAsterisksCollapseTest;
begin
  // '**' must behave the same as '*'
  Assert.IsTrue(TWildCard.Match('anything',  '**'));
  Assert.IsTrue(TWildCard.Match('a.b.c.txt', '**.txt'));
  Assert.IsTrue(TWildCard.Match('a.b.c.txt', '***.txt'));
end;

{ Spec example 2: '?' }

procedure TWildCardMatcherDUnitX.QuestionMarkMatchesSingleCharTest;
begin
  // b?ll finds ball, bell, bill (from the spec)
  Assert.IsTrue(TWildCard.Match('ball', 'b?ll'));
  Assert.IsTrue(TWildCard.Match('bell', 'b?ll'));
  Assert.IsTrue(TWildCard.Match('bill', 'b?ll'));
end;

procedure TWildCardMatcherDUnitX.QuestionMarkRequiresACharacterTest;
begin
  // '?' must consume exactly one char - 'bll' has none to consume
  Assert.IsFalse(TWildCard.Match('bll',  'b?ll'), '"bll" has no middle char');
  Assert.IsFalse(TWildCard.Match('baal', 'b?ll'), '"baal" has two middle chars');
end;

{ Spec example 3: '[abc]' }

procedure TWildCardMatcherDUnitX.CharClassPositiveSetTest;
begin
  // b[ae]ll finds ball and bell, but not bill (from the spec)
  Assert.IsTrue (TWildCard.Match('ball', 'b[ae]ll'));
  Assert.IsTrue (TWildCard.Match('bell', 'b[ae]ll'));
  Assert.IsFalse(TWildCard.Match('bill', 'b[ae]ll'));
end;

{ Spec example 4: '[!abc]' }

procedure TWildCardMatcherDUnitX.CharClassNegatedSetTest;
begin
  // b[!ae]ll finds bill and bull, but not ball or bell (from the spec)
  Assert.IsTrue (TWildCard.Match('bill', 'b[!ae]ll'));
  Assert.IsTrue (TWildCard.Match('bull', 'b[!ae]ll'));
  Assert.IsFalse(TWildCard.Match('ball', 'b[!ae]ll'));
  Assert.IsFalse(TWildCard.Match('bell', 'b[!ae]ll'));
end;

procedure TWildCardMatcherDUnitX.NegatedSetAtStartSpecExampleTest;
begin
  // From the spec: "[!a]*" finds all items that do not begin with 'a'.
  Assert.IsTrue (TWildCard.Match('banana', '[!a]*'));
  Assert.IsTrue (TWildCard.Match('zebra',  '[!a]*'));
  Assert.IsTrue (TWildCard.Match('x',      '[!a]*'));
  Assert.IsFalse(TWildCard.Match('apple',  '[!a]*'));
  Assert.IsFalse(TWildCard.Match('a',      '[!a]*'));
end;

{ Spec example 5: '[a-c]' }

procedure TWildCardMatcherDUnitX.CharClassRangeTest;
begin
  // b[a-c]d finds bad, bbd, bcd (from the spec)
  Assert.IsTrue (TWildCard.Match('bad', 'b[a-c]d'));
  Assert.IsTrue (TWildCard.Match('bbd', 'b[a-c]d'));
  Assert.IsTrue (TWildCard.Match('bcd', 'b[a-c]d'));
  Assert.IsFalse(TWildCard.Match('bdd', 'b[a-c]d'));
  Assert.IsFalse(TWildCard.Match('b0d', 'b[a-c]d'));
end;

procedure TWildCardMatcherDUnitX.CombinedRangesTest;
begin
  // Multiple ranges in one class
  Assert.IsTrue (TWildCard.Match('X', '[a-zA-Z]'));
  Assert.IsTrue (TWildCard.Match('x', '[a-zA-Z]'));
  Assert.IsFalse(TWildCard.Match('5', '[a-zA-Z]'));

  // Range + literals + digits
  Assert.IsTrue (TWildCard.Match('q',  '[a-cq0-9]'));
  Assert.IsTrue (TWildCard.Match('b',  '[a-cq0-9]'));
  Assert.IsTrue (TWildCard.Match('7',  '[a-cq0-9]'));
  Assert.IsFalse(TWildCard.Match('z',  '[a-cq0-9]'));
end;

procedure TWildCardMatcherDUnitX.NegatedRangeTest;
begin
  Assert.IsTrue (TWildCard.Match('1', '[!a-z]'));
  Assert.IsTrue (TWildCard.Match('!', '[!a-z]'));
  Assert.IsFalse(TWildCard.Match('m', '[!a-z]'));
end;

{ Spec example 6: '#' }

procedure TWildCardMatcherDUnitX.HashMatchesSingleDigitTest;
begin
  // 1#3 finds 103, 113, 123 (from the spec)
  Assert.IsTrue(TWildCard.Match('103', '1#3'));
  Assert.IsTrue(TWildCard.Match('113', '1#3'));
  Assert.IsTrue(TWildCard.Match('123', '1#3'));
  Assert.IsTrue(TWildCard.Match('193', '1#3'));
end;

procedure TWildCardMatcherDUnitX.HashRejectsNonDigitTest;
begin
  Assert.IsFalse(TWildCard.Match('1a3', '1#3'), '"a" is not a digit');
  Assert.IsFalse(TWildCard.Match('1 3', '1#3'), 'space is not a digit');
  Assert.IsFalse(TWildCard.Match('13',  '1#3'), '"#" must consume exactly one digit');
end;

{ Edge cases }

procedure TWildCardMatcherDUnitX.EmptyPatternMatchesOnlyEmptyInputTest;
begin
  Assert.IsTrue (TWildCard.Match('', ''));
  Assert.IsFalse(TWildCard.Match('x', ''));
end;

procedure TWildCardMatcherDUnitX.EmptyInputMatchesOnlyEmptyOrAsteriskTest;
begin
  Assert.IsTrue (TWildCard.Match('', ''));
  Assert.IsTrue (TWildCard.Match('', '*'));
  Assert.IsTrue (TWildCard.Match('', '***'));
  Assert.IsFalse(TWildCard.Match('', '?'));
  Assert.IsFalse(TWildCard.Match('', '#'));
  Assert.IsFalse(TWildCard.Match('', 'a'));
  Assert.IsFalse(TWildCard.Match('', '[a-z]'));
end;

procedure TWildCardMatcherDUnitX.ExactLiteralMatchTest;
begin
  Assert.IsTrue (TWildCard.Match('readme.txt', 'readme.txt'));
  Assert.IsFalse(TWildCard.Match('readme.txt', 'readme.doc'));
  Assert.IsFalse(TWildCard.Match('readme.txt', 'readme.tx'),  'shorter pattern must not match');
  Assert.IsFalse(TWildCard.Match('readme.tx',  'readme.txt'), 'shorter input must not match');
end;

procedure TWildCardMatcherDUnitX.LiteralCaseInsensitiveByDefaultTest;
begin
  // Default is case-insensitive (Windows convention)
  Assert.IsTrue(TWildCard.Match('README.TXT', 'readme.txt'));
  Assert.IsTrue(TWildCard.Match('ReadMe.Txt', '*.TXT'));
  Assert.IsTrue(TWildCard.Match('FOO', '[a-z]??'));
end;

procedure TWildCardMatcherDUnitX.CaseSensitiveFlagTest;
begin
  Assert.IsFalse(TWildCard.Match('README.TXT', 'readme.txt', True));
  Assert.IsTrue (TWildCard.Match('readme.txt', 'readme.txt', True));
  Assert.IsFalse(TWildCard.Match('FOO',        '[a-z]??',    True));
  Assert.IsTrue (TWildCard.Match('foo',        '[a-z]??',    True));
end;

procedure TWildCardMatcherDUnitX.UnterminatedClassReturnsFalseTest;
begin
  // Patterns with an unterminated '[' are malformed - never match
  Assert.IsFalse(TWildCard.Match('a',  '[abc'));
  Assert.IsFalse(TWildCard.Match('ab', 'a[bc'));
end;

procedure TWildCardMatcherDUnitX.EmptyClassReturnsFalseTest;
begin
  // '[]' is treated as an unterminated class with ']' as literal content;
  // the next ']' would close it. Bare '[]' on its own is malformed.
  Assert.IsFalse(TWildCard.Match('a', '[]'));
end;

procedure TWildCardMatcherDUnitX.LiteralCloseBracketAsFirstClassCharTest;
begin
  // First content char ']' is a literal - '[]abc]' matches ']', 'a', 'b' or 'c'
  Assert.IsTrue (TWildCard.Match(']', '[]abc]'));
  Assert.IsTrue (TWildCard.Match('a', '[]abc]'));
  Assert.IsTrue (TWildCard.Match('c', '[]abc]'));
  Assert.IsFalse(TWildCard.Match('x', '[]abc]'));
end;

procedure TWildCardMatcherDUnitX.DashAsLiteralAtStartOrEndOfClassTest;
begin
  // '-' at the start/end of a class is a literal, not part of a range
  Assert.IsTrue (TWildCard.Match('-', '[-x]'));
  Assert.IsTrue (TWildCard.Match('x', '[-x]'));
  Assert.IsTrue (TWildCard.Match('-', '[a-]'));
  Assert.IsTrue (TWildCard.Match('a', '[a-]'));
  Assert.IsFalse(TWildCard.Match('b', '[a-]'));
end;

{ Combinations }

procedure TWildCardMatcherDUnitX.ComplexFileNameLikePatternsTest;
begin
  // Realistic file-mask style patterns
  Assert.IsTrue (TWildCard.Match('Foo1.pas',  '*.pas'));
  Assert.IsTrue (TWildCard.Match('Foo1.pas',  'Foo?.pas'));
  Assert.IsTrue (TWildCard.Match('Foo7.pas',  'Foo#.pas'));
  Assert.IsFalse(TWildCard.Match('FooA.pas',  'Foo#.pas'));
  Assert.IsTrue (TWildCard.Match('Test_001.log', 'Test_###.log'));
  Assert.IsFalse(TWildCard.Match('Test_00A.log', 'Test_###.log'));
end;

procedure TWildCardMatcherDUnitX.MixedSpecialCharsInClassTest;
begin
  // Class combining range + literal digit + literal letter
  Assert.IsTrue (TWildCard.Match('Foo_5.pas', 'Foo[_-]#.pas'));
  Assert.IsTrue (TWildCard.Match('Foo-5.pas', 'Foo[_-]#.pas'));
  Assert.IsFalse(TWildCard.Match('Foo.5.pas', 'Foo[_-]#.pas'));
end;

procedure TWildCardMatcherDUnitX.ManyAsterisksDoNotExplodeTest;
begin
  // Defensive: pathological pattern with many '*' should still terminate
  // quickly thanks to the consecutive-asterisk collapse.
  Assert.IsTrue (TWildCard.Match('abcdefghijklmnop',
    '*a*b*c*d*e*f*g*h*i*j*k*l*m*n*o*p*'));
  Assert.IsFalse(TWildCard.Match('abcdefghijklmnop',
    '*a*b*c*d*e*f*g*h*i*j*k*l*m*n*o*z*'));
end;

{ '|' extension: one-or-more line endings }

procedure TWildCardMatcherDUnitX.PipeMatchesSingleCrlfTest;
begin
  Assert.IsTrue(TWildCard.Match('file' + #13#10 + 'name', 'file|name'));
end;

procedure TWildCardMatcherDUnitX.PipeMatchesSingleLfTest;
begin
  Assert.IsTrue(TWildCard.Match('file' + #10 + 'name', 'file|name'));
end;

procedure TWildCardMatcherDUnitX.PipeMatchesSingleCrTest;
begin
  Assert.IsTrue(TWildCard.Match('file' + #13 + 'name', 'file|name'));
end;

procedure TWildCardMatcherDUnitX.PipeMatchesMultipleEolsTest;
begin
  // '|' is greedy on EOLs - a blank line / paragraph break must still match
  Assert.IsTrue(TWildCard.Match('file' + #13#10 + #13#10 + 'name', 'file|name'));
  Assert.IsTrue(TWildCard.Match('file' + #10 + #10 + #10 + 'name', 'file|name'));
end;

procedure TWildCardMatcherDUnitX.PipeMatchesMixedEolsTest;
begin
  // Mixed CRLF + LF + CR run between the two words still counts as "one or
  // more line endings" and must match.
  Assert.IsTrue(TWildCard.Match('file' + #13#10 + #10 + #13 + 'name', 'file|name'));
end;

procedure TWildCardMatcherDUnitX.PipeRequiresAtLeastOneEolTest;
begin
  // 'filename' has no EOL between the two halves - '|' must NOT match zero
  Assert.IsFalse(TWildCard.Match('filename', 'file|name'));
  // Tab or space is not an EOL
  Assert.IsFalse(TWildCard.Match('file' + #9 + 'name',  'file|name'));
  Assert.IsFalse(TWildCard.Match('file' + ' ' + 'name', 'file|name'));
end;

procedure TWildCardMatcherDUnitX.PipeDoesNotMatchEndOfInputTest;
begin
  // End-of-input must NOT be treated as an implicit EOL by '|'
  Assert.IsFalse(TWildCard.Match('file', 'file|'));
  Assert.IsFalse(TWildCard.Match('',     '|'));
end;

procedure TWildCardMatcherDUnitX.ConsecutivePipesCollapseTest;
begin
  // '||' must behave like '|' - still "one or more" EOLs, not "exactly two"
  Assert.IsTrue(TWildCard.Match('a' + #10 + 'b',         'a||b'));
  Assert.IsTrue(TWildCard.Match('a' + #10 + #10 + 'b',   'a||b'));
  Assert.IsTrue(TWildCard.Match('a' + #13#10 + 'b',      'a|||b'));
end;

procedure TWildCardMatcherDUnitX.PipeAtStartAndEndOfPatternTest;
begin
  // '|name' - input must start with EOL(s) then 'name'
  Assert.IsTrue (TWildCard.Match(#10 + 'name',         '|name'));
  Assert.IsTrue (TWildCard.Match(#13#10 + #10 + 'name', '|name'));
  Assert.IsFalse(TWildCard.Match('name',                '|name'));

  // 'file|' - input must end with EOL(s) (any amount)
  Assert.IsTrue (TWildCard.Match('file' + #10,        'file|'));
  Assert.IsTrue (TWildCard.Match('file' + #13#10#13#10, 'file|'));
  Assert.IsFalse(TWildCard.Match('file',              'file|'));
end;

procedure TWildCardMatcherDUnitX.PipeCombinedWithAsteriskTest;
begin
  // '*|*' = anything, then a real line break, then anything.
  Assert.IsTrue (TWildCard.Match('foo' + #13#10 + 'bar', '*|*'));
  Assert.IsTrue (TWildCard.Match('a b c' + #10 + 'x y z', '*|*'));
  Assert.IsFalse(TWildCard.Match('all on one line',      '*|*'), 'no EOL anywhere');

  // '|*foo' = starts with EOL(s) then anything then 'foo'
  Assert.IsTrue (TWildCard.Match(#10 + 'xxxfoo', '|*foo'));
  Assert.IsFalse(TWildCard.Match('xxxfoo',      '|*foo'), 'missing leading EOL');
end;

procedure TWildCardMatcherDUnitX.PipeStructuralMatchTest;
const
  CR_LF = #13#10;
var
  LSource: string;
begin
  // Realistic use case: matching the structural shape of a Delphi unit
  // across line boundaries using '|' as the line-break anchor.
  LSource :=
    'unit Foo;'                  + CR_LF +
    CR_LF +
    'interface'                  + CR_LF +
    CR_LF +
    'procedure Bar;'             + CR_LF +
    CR_LF +
    'implementation'             + CR_LF +
    CR_LF +
    'procedure Bar;'             + CR_LF +
    'begin'                      + CR_LF +
    'end;'                       + CR_LF +
    CR_LF +
    'end.';

  Assert.IsTrue(TWildCard.Match(LSource,
    'unit *;|interface|*|implementation|*|end.'));
  Assert.IsFalse(TWildCard.Match(LSource,
    'unit *;|interface|*|missingsection|*|end.'));
end;

{ Multi-pattern overloads }

procedure TWildCardMatcherDUnitX.MatchTArrayReturnsTrueWhenAnyMatchesTest;
begin
  // Should match because the second pattern matches '*.pas'
  Assert.IsTrue(TWildCard.Match('Unit1.pas', TArray<string>.Create('*.txt', '*.pas', '*.dpr')));
  // Single-element array still works
  Assert.IsTrue(TWildCard.Match('Unit1.pas', TArray<string>.Create('*.pas')));
end;

procedure TWildCardMatcherDUnitX.MatchTArrayReturnsFalseWhenNoneMatchTest;
begin
  Assert.IsFalse(TWildCard.Match('Unit1.pas', TArray<string>.Create('*.txt', '*.doc', '*.csv')));
end;

procedure TWildCardMatcherDUnitX.MatchTArrayEmptyReturnsFalseTest;
begin
  // Empty pattern list - nothing to match against, must return False
  Assert.IsFalse(TWildCard.Match('anything', TArray<string>.Create()));
end;

procedure TWildCardMatcherDUnitX.MatchTArrayShortCircuitsOnFirstMatchTest;
var
  LPatterns: TArray<string>;
begin
  // First pattern matches; later malformed pattern must not be evaluated.
  // If short-circuiting works, the unterminated '[' never gets visited.
  LPatterns := TArray<string>.Create('*.pas', '[unterminated');
  Assert.IsTrue(TWildCard.Match('Unit1.pas', LPatterns));
end;

procedure TWildCardMatcherDUnitX.MatchTArrayHonoursCaseSensitiveFlagTest;
var
  LPatterns: TArray<string>;
begin
  LPatterns := TArray<string>.Create('*.PAS', '*.DPR');

  Assert.IsTrue (TWildCard.Match('unit1.pas', LPatterns, False), 'case-insensitive default');
  Assert.IsFalse(TWildCard.Match('unit1.pas', LPatterns, True),  'case-sensitive should not match');
end;

procedure TWildCardMatcherDUnitX.MatchTStringsReturnsTrueWhenAnyMatchesTest;
var
  LList: TStringList;
begin
  LList := TStringList.Create;
  try
    LList.Add('*.txt');
    LList.Add('*.pas');
    LList.Add('*.dpr');

    Assert.IsTrue(TWildCard.Match('Unit1.pas', LList));
  finally
    LList.Free;
  end;
end;

procedure TWildCardMatcherDUnitX.MatchTStringsReturnsFalseWhenNoneMatchTest;
var
  LList: TStringList;
begin
  LList := TStringList.Create;
  try
    LList.Add('*.txt');
    LList.Add('*.doc');

    Assert.IsFalse(TWildCard.Match('Unit1.pas', LList));
  finally
    LList.Free;
  end;
end;

procedure TWildCardMatcherDUnitX.MatchTStringsEmptyReturnsFalseTest;
var
  LList: TStringList;
begin
  LList := TStringList.Create;
  try
    Assert.IsFalse(TWildCard.Match('anything', LList));
  finally
    LList.Free;
  end;
end;

procedure TWildCardMatcherDUnitX.MatchTStringsHonoursCaseSensitiveFlagTest;
var
  LList: TStringList;
begin
  LList := TStringList.Create;
  try
    LList.Add('*.PAS');
    LList.Add('*.DPR');

    Assert.IsTrue (TWildCard.Match('unit1.pas', LList, False));
    Assert.IsFalse(TWildCard.Match('unit1.pas', LList, True));
  finally
    LList.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TWildCardMatcherDUnitX);

end.
