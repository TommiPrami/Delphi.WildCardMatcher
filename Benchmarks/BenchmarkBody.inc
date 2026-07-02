// Shared body of the WildCardMatcher benchmark - included by BOTH
// Delphi.WildCardMatcher.Benchmark.dpr (current Source\ unit) and
// Baseline\Delphi.WildCardMatcher.BaselineBenchmark.dpr (frozen
// pre-optimization unit from commit 0e83678).  Keeping the body in one
// include guarantees both programs always run identical scenarios, so
// their numbers stay comparable.
//
// Every timed variant runs BENCH_ROUNDS times and reports the BEST round -
// the machine is never idle, so single-shot timings fluctuate; the minimum
// is the closest estimate of the undisturbed cost.

const
  BENCH_ROUNDS = 5;

  BULK_INPUT_COUNT = 1000;
  BULK_LOOPS = 1000;
  WORST_CASE_LOOPS = 100_000;

  WORST_CASE_LONG_PATH = 'C:\Users\developer\source\repos\MyApp\src\main\delphi\modules\data_access\repositories\implementations\sqlserver\'
    + 'concrete\OrderRepositoryImplementation_2024_03_15_v3_revised_final.pas';
  WORST_CASE_COMPLEX_PATTERN = '*\Users\*\source\*\MyApp\*\modules\*\repositories\*\sqlserver\*\*Repository*_v#_*.xyz';

type
  TBenchRun = reference to function: Int64; // returns total match count

var
  GParityFailures: Integer = 0;

{ ----------------------------------------------------------------------- }
{ Parity suite: registered engine vs ad-hoc engine                         }
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

  WriteLn('Parity suite passed (registered vs ad-hoc engine, CI + CS).');
end;

{ ----------------------------------------------------------------------- }
{ Benchmark plumbing                                                       }
{ ----------------------------------------------------------------------- }

// Runs ARun BENCH_ROUNDS times, validates the match count every round and
// reports the BEST (minimum) time.
procedure TimeVariant(const AVariant: string; const ATotalOps, AExpectedTotal: Int64;
  const ARun: TBenchRun);
var
  LRound: Integer;
  LWatch: TStopwatch;
  LMatches: Int64;
  LMs, LBestMs: Double;
  LNsPerOp: Double;
begin
  LBestMs := 0;

  for LRound := 1 to BENCH_ROUNDS do
  begin
    LWatch := TStopwatch.StartNew;
    LMatches := ARun();
    LWatch.Stop;

    if LMatches <> AExpectedTotal then
    begin
      WriteLn(Format('  %-24s MATCH-COUNT MISMATCH: expected %d, got %d - RESULT INVALID',
        [AVariant, AExpectedTotal, LMatches]));
      Halt(1);
    end;

    LMs := LWatch.Elapsed.TotalMilliseconds;

    if (LRound = 1) or (LMs < LBestMs) then
      LBestMs := LMs;
  end;

  LNsPerOp := (LBestMs * 1_000_000.0) / ATotalOps;
  WriteLn(Format('  %-24s %10.1f ns/op   (best %8.2f ms, %d ops)',
    [AVariant, LNsPerOp, LBestMs, ATotalOps]));
end;

// Times four variants over the same inputs / patterns:
//   registered CI/CS - patterns handed to Create, Match(input)
//   ad-hoc CI/CS     - empty Create, Match(input, patterns) per call
// Note: inputs are constructed so the expected match count is the same in
// CS mode as in CI mode (exact-case inputs).
procedure RunScenario(const AName: string; const AInputs: TArray<string>;
  const APatterns: TArray<string>; const ALoops: Integer; const AExpectedPerIter: Integer);
var
  LRegisteredCI, LRegisteredCS, LAdhocCI, LAdhocCS: TWildCard;
  LTotalOps, LExpectedTotal: Int64;
begin
  WriteLn;
  WriteLn(Format('=== %s  (%d patterns x %d inputs x %d loops, best of %d rounds) ===',
    [AName, Length(APatterns), Length(AInputs), ALoops, BENCH_ROUNDS]));

  LTotalOps := Int64(ALoops) * Length(AInputs);
  LExpectedTotal := Int64(ALoops) * AExpectedPerIter;

  LRegisteredCI := TWildCard.Create(APatterns, False);
  LRegisteredCS := TWildCard.Create(APatterns, True);
  LAdhocCI := TWildCard.Create(False);
  LAdhocCS := TWildCard.Create(True);

  TimeVariant('registered CI', LTotalOps, LExpectedTotal,
    function: Int64
    var
      LIter, LIdx: Integer;
    begin
      Result := 0;
      for LIter := 1 to ALoops do
        for LIdx := 0 to High(AInputs) do
          if LRegisteredCI.Match(AInputs[LIdx]) then
            Inc(Result);
    end);

  TimeVariant('ad-hoc CI', LTotalOps, LExpectedTotal,
    function: Int64
    var
      LIter, LIdx: Integer;
    begin
      Result := 0;
      for LIter := 1 to ALoops do
        for LIdx := 0 to High(AInputs) do
          if LAdhocCI.Match(AInputs[LIdx], APatterns) then
            Inc(Result);
    end);

  TimeVariant('registered CS', LTotalOps, LExpectedTotal,
    function: Int64
    var
      LIter, LIdx: Integer;
    begin
      Result := 0;
      for LIter := 1 to ALoops do
        for LIdx := 0 to High(AInputs) do
          if LRegisteredCS.Match(AInputs[LIdx]) then
            Inc(Result);
    end);

  TimeVariant('ad-hoc CS', LTotalOps, LExpectedTotal,
    function: Int64
    var
      LIter, LIdx: Integer;
    begin
      Result := 0;
      for LIter := 1 to ALoops do
        for LIdx := 0 to High(AInputs) do
          if LAdhocCS.Match(AInputs[LIdx], APatterns) then
            Inc(Result);
    end);
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
