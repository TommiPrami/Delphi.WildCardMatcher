program Delphi.WildCardMatcher.Benchmark;

// Permanent performance harness for Delphi.WildCardMatcher.
//
// TWildCard has two engines that MUST agree:
//   registered - patterns compiled to token programs at Create
//                (TWildCard.Create(patterns).Match(input))
//   ad-hoc     - interpreting engine, pattern scanned per call
//                (TWildCard.Create.Match(input, pattern))
//
// The parity suite below runs every edge case through both engines (CI
// and CS) and aborts if they ever disagree - run it after ANY change to
// the matcher.  The scenario section then times both engines so
// regressions and improvements are visible as ns/op numbers.  Historical
// results live in RESULTS.md next to this file.
//
// Adding a new benchmark scenario: append a RunScenario call in the main
// block - name, inputs, patterns, loop count, expected matches per
// iteration.  Adding a parity case: one CheckParity(pattern, input) line.
//
// Build & run (optimization ON - do not benchmark Debug builds):
//   "%ProgramFiles(x86)%\Embarcadero\Studio\37.0\bin\rsvars.bat"
//   dcc32 -B -$O+ -$R- -$Q- -U"..\Source" -E"Win32" -N"Win32" Delphi.WildCardMatcher.Benchmark.dpr
//   Win32\Delphi.WildCardMatcher.Benchmark.exe

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Diagnostics,
  Delphi.WildCardMatcher in '..\Source\Delphi.WildCardMatcher.pas';

const
  BULK_INPUT_COUNT = 1000;
  BULK_LOOPS = 1000;
  WORST_CASE_LOOPS = 100_000;

  WORST_CASE_LONG_PATH = 'C:\Users\developer\source\repos\MyApp\src\main\delphi\modules\data_access\repositories\implementations\sqlserver\'
    + 'concrete\OrderRepositoryImplementation_2024_03_15_v3_revised_final.pas';
  WORST_CASE_COMPLEX_PATTERN = '*\Users\*\source\*\MyApp\*\modules\*\repositories\*\sqlserver\*\*Repository*_v#_*.xyz';

var
  GParityFailures: Integer = 0;

{ ----------------------------------------------------------------------- }
{ Parity suite: registered (compiled) vs ad-hoc (interpreting)             }
{ ----------------------------------------------------------------------- }

procedure CheckParity(const APattern, AInput: string);
var
  LAdhocCI, LAdhocCS, LRegCI, LRegCS: Boolean;
begin
  LAdhocCI := TWildCard.Create.Match(AInput, APattern);
  LRegCI := TWildCard.Create(APattern).Match(AInput);

  LAdhocCS := TWildCard.Create(True).Match(AInput, APattern);
  LRegCS := TWildCard.Create(APattern, True).Match(AInput);

  if LAdhocCI <> LRegCI then
  begin
    Inc(GParityFailures);
    WriteLn(Format('PARITY FAIL (CI): pattern=<%s> input=<%s> ad-hoc=%s registered=%s',
      [APattern, AInput, BoolToStr(LAdhocCI, True), BoolToStr(LRegCI, True)]));
  end;

  if LAdhocCS <> LRegCS then
  begin
    Inc(GParityFailures);
    WriteLn(Format('PARITY FAIL (CS): pattern=<%s> input=<%s> ad-hoc=%s registered=%s',
      [APattern, AInput, BoolToStr(LAdhocCS, True), BoolToStr(LRegCS, True)]));
  end;
end;

procedure RunParitySuite;
begin
  // '*' / '?' / '#' basics
  CheckParity('wh*', 'what');
  CheckParity('wh*', 'awhile');
  CheckParity('*', '');
  CheckParity('', '');
  CheckParity('', 'x');
  CheckParity('*.txt', 'readme.txt');
  CheckParity('*.txt', 'readme.doc');
  CheckParity('*world*', 'hello world');
  CheckParity('*world*', 'hello');
  CheckParity('b?ll', 'ball');
  CheckParity('b?ll', 'bll');
  CheckParity('1#3', '103');
  CheckParity('1#3', '1a3');
  CheckParity('1#3', '13');
  CheckParity('*?', '');
  CheckParity('*?', 'x');
  CheckParity('?*', 'x');
  CheckParity('**.txt', 'a.b.c.txt');
  CheckParity('*a*b*c*', 'xaxbxcx');
  CheckParity('*a*b*c*', 'xxxxxx');
  CheckParity('Test_###.log', 'Test_001.log');
  CheckParity('Test_###.log', 'Test_00A.log');
  CheckParity('*.pas', 'pas');
  CheckParity('*.pas', '.pas');

  // Char classes
  CheckParity('b[ae]ll', 'bell');
  CheckParity('b[ae]ll', 'bill');
  CheckParity('b[!ae]ll', 'bull');
  CheckParity('b[!ae]ll', 'ball');
  CheckParity('b[a-c]d', 'bbd');
  CheckParity('b[a-c]d', 'bdd');
  CheckParity('[a-zA-Z]', 'X');
  CheckParity('[a-zA-Z]', '5');
  CheckParity('[!a]*', 'apple');
  CheckParity('[!a]*', 'zebra');
  CheckParity('[]abc]', ']');
  CheckParity('[]abc]', 'x');
  CheckParity('[-x]', '-');
  CheckParity('[a-]', '-');
  CheckParity('[a-]', 'b');
  CheckParity('[abc', 'a');
  CheckParity('[]', 'a');
  CheckParity('Foo[_-]#.pas', 'Foo_5.pas');
  CheckParity('Foo[_-]#.pas', 'Foo.5.pas');
  CheckParity('*[abc]end', 'xxxaend');
  CheckParity('*[abc]end', 'xxxdend');

  // Quoted alternation
  CheckParity('["foo"]', 'foo');
  CheckParity('["foo"]', 'fo');
  CheckParity('["foo"|"bar"]', 'bar');
  CheckParity('["foo"|"bar"]', 'qux');
  CheckParity('*["foo"|"bar"]*', 'xxbaryy');
  CheckParity('*["foo"|"bar"]*', 'xxxxxx');
  CheckParity('["a"|"ab"]b', 'abb');
  CheckParity('["a"|"ab"]b', 'ab');
  CheckParity('[""]foo', 'foo');
  CheckParity('foo[""]', 'foo');
  CheckParity('[""|"foo"]bar', 'foobar');
  CheckParity('[!"foo"|"bar"]*', 'quxsuffix');
  CheckParity('[!"foo"|"bar"]*', 'foosuffix');
  CheckParity('[!"foo"|"barbaz"]-tail', 'abcdef-tail');
  CheckParity('[!"foo"|"barbaz"]-tail', 'barbaz-tail');
  CheckParity('[!"foo"|"bar"]', 'ab');
  CheckParity('["foo', 'foo');
  CheckParity('["foo"|"bar', 'foo');
  CheckParity('["foo""bar"]', 'foo');
  CheckParity('["foo"x"bar"]', 'foo');
  CheckParity('["a]b"]', 'a]b');
  CheckParity('["[x]"]', '[x]');
  CheckParity('*["3rdparty"|"ThirdParty"]*.md', 'docs\3rdparty\notes.md');
  CheckParity('*["3rdparty"|"ThirdParty"]*.md', 'docs\internal\notes.md');

  // '|' literal outside classes
  CheckParity('a|b', 'a|b');
  CheckParity('a|b', 'ab');

  // Worst-case pattern parity
  CheckParity(WORST_CASE_COMPLEX_PATTERN, WORST_CASE_LONG_PATH);

  if GParityFailures > 0 then
  begin
    WriteLn;
    WriteLn(Format('PARITY SUITE FAILED: %d mismatches - benchmark aborted.', [GParityFailures]));
    Halt(1);
  end;

  WriteLn('Parity suite passed (registered/compiled vs ad-hoc/interpreting, CI + CS).');
end;

{ ----------------------------------------------------------------------- }
{ Benchmark plumbing                                                       }
{ ----------------------------------------------------------------------- }

procedure Report(const AVariant: string; const ATotalOps: Int64; const AElapsedMs: Double;
  const AMatches, AExpected: Int64);
var
  LNsPerOp: Double;
begin
  if AMatches <> AExpected then
  begin
    WriteLn(Format('  %-24s MATCH-COUNT MISMATCH: expected %d, got %d - RESULT INVALID',
      [AVariant, AExpected, AMatches]));
    Halt(1);
  end;

  LNsPerOp := (AElapsedMs * 1_000_000.0) / ATotalOps;
  WriteLn(Format('  %-24s %10.1f ns/op   (%8.2f ms, %d ops)',
    [AVariant, LNsPerOp, AElapsedMs, ATotalOps]));
end;

// Times four variants over the same inputs / patterns:
//   registered CI/CS - compiled engine (Create with patterns, then Match)
//   ad-hoc CI/CS     - interpreting engine (empty Create, Match with patterns)
// Note: inputs are constructed so the expected match count is the same in
// CS mode as in CI mode (exact-case inputs).
procedure RunScenario(const AName: string; const AInputs: TArray<string>;
  const APatterns: TArray<string>; const ALoops: Integer; const AExpectedPerIter: Integer);
var
  LRegistered, LAdhoc: TWildCard;
  LWatch: TStopwatch;
  LIter, LIdx: Integer;
  LMatches: Int64;
  LTotalOps, LExpectedTotal: Int64;
begin
  WriteLn;
  WriteLn(Format('=== %s  (%d patterns x %d inputs x %d loops) ===',
    [AName, Length(APatterns), Length(AInputs), ALoops]));

  LTotalOps := Int64(ALoops) * Length(AInputs);
  LExpectedTotal := Int64(ALoops) * AExpectedPerIter;

  // --- registered CI (compiled engine) ---
  LRegistered := TWildCard.Create(APatterns, False);
  LMatches := 0;
  LWatch := TStopwatch.StartNew;

  for LIter := 1 to ALoops do
    for LIdx := 0 to High(AInputs) do
      if LRegistered.Match(AInputs[LIdx]) then
        Inc(LMatches);

  LWatch.Stop;
  Report('registered CI', LTotalOps, LWatch.Elapsed.TotalMilliseconds, LMatches, LExpectedTotal);

  // --- ad-hoc CI (interpreting engine) ---
  LAdhoc := TWildCard.Create(False);
  LMatches := 0;
  LWatch := TStopwatch.StartNew;

  for LIter := 1 to ALoops do
    for LIdx := 0 to High(AInputs) do
      if LAdhoc.Match(AInputs[LIdx], APatterns) then
        Inc(LMatches);

  LWatch.Stop;
  Report('ad-hoc CI', LTotalOps, LWatch.Elapsed.TotalMilliseconds, LMatches, LExpectedTotal);

  // --- registered CS (compiled engine, ordinal) ---
  LRegistered := TWildCard.Create(APatterns, True);
  LMatches := 0;
  LWatch := TStopwatch.StartNew;

  for LIter := 1 to ALoops do
    for LIdx := 0 to High(AInputs) do
      if LRegistered.Match(AInputs[LIdx]) then
        Inc(LMatches);

  LWatch.Stop;
  Report('registered CS', LTotalOps, LWatch.Elapsed.TotalMilliseconds, LMatches, LExpectedTotal);

  // --- ad-hoc CS (interpreting engine, ordinal) ---
  LAdhoc := TWildCard.Create(True);
  LMatches := 0;
  LWatch := TStopwatch.StartNew;

  for LIter := 1 to ALoops do
    for LIdx := 0 to High(AInputs) do
      if LAdhoc.Match(AInputs[LIdx], APatterns) then
        Inc(LMatches);

  LWatch.Stop;
  Report('ad-hoc CS', LTotalOps, LWatch.Elapsed.TotalMilliseconds, LMatches, LExpectedTotal);
end;

{ ----------------------------------------------------------------------- }
{ Main                                                                     }
{ ----------------------------------------------------------------------- }

var
  GBulkInputs: TArray<string>;
  GAltInputs: TArray<string>;
  GWorstInput: TArray<string>;
  GIdx: Integer;

begin
  try
    RunParitySuite;

    // Bulk inputs: 5% 'MatchMe_####.pas', 95% 'Skip_####.txt' (same shape
    // as the DUnitX speed fixtures).  Case matches the patterns exactly so
    // CS and CI expect the same counts.
    SetLength(GBulkInputs, BULK_INPUT_COUNT);
    for GIdx := 0 to (BULK_INPUT_COUNT div 20) - 1 do
      GBulkInputs[GIdx] := Format('MatchMe_%.4d.pas', [GIdx]);
    for GIdx := BULK_INPUT_COUNT div 20 to BULK_INPUT_COUNT - 1 do
      GBulkInputs[GIdx] := Format('Skip_%.4d.txt', [GIdx]);

    // Quoted-alt inputs: 5% under a 3rdparty folder, 95% elsewhere.
    SetLength(GAltInputs, BULK_INPUT_COUNT);
    for GIdx := 0 to (BULK_INPUT_COUNT div 20) - 1 do
      GAltInputs[GIdx] := Format('docs\3rdparty\notes_%.4d.md', [GIdx]);
    for GIdx := BULK_INPUT_COUNT div 20 to BULK_INPUT_COUNT - 1 do
      GAltInputs[GIdx] := Format('docs\internal\notes_%.4d.txt', [GIdx]);

    GWorstInput := TArray<string>.Create(WORST_CASE_LONG_PATH);

    RunScenario('S1 single mask *.pas', GBulkInputs,
      TArray<string>.Create('*.pas'),
      BULK_LOOPS, BULK_INPUT_COUNT div 20);

    RunScenario('S2 8-mask ignore set', GBulkInputs,
      TArray<string>.Create('*.pas', '*.dpr', '*.dpk', '*.inc', '*.dfm', '*.res', '*.dproj', '*.groupproj'),
      BULK_LOOPS, BULK_INPUT_COUNT div 20);

    RunScenario('S3 worst-case backtracking', GWorstInput,
      TArray<string>.Create(WORST_CASE_COMPLEX_PATTERN),
      WORST_CASE_LOOPS, 0);

    RunScenario('S4 quoted-alt mask', GAltInputs,
      TArray<string>.Create('*["3rdparty"|"ThirdParty"]*.md'),
      BULK_LOOPS, BULK_INPUT_COUNT div 20);

    WriteLn;
    WriteLn('Benchmark complete.');
  except
    on E: Exception do
    begin
      WriteLn(E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
