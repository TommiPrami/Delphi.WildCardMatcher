unit Delphi.WildCardMatcher;

// Windows / DOS style wildcard matcher with a few common extensions.
//
//   *                  matches zero or more characters
//   ?                  matches exactly one character
//   #                  matches exactly one decimal digit (0-9)
//   [abc]              matches any one of the characters in the set
//   [!abc]             matches any one character NOT in the set
//   [a-z]              matches any one character in the range (low..high, ascending)
//   ["foo"|"bar"]      matches the literal "foo" OR the literal "bar" at this position
//   [!"foo"|"bar"]     matches a slice of length max(altLen) that is NEITHER prefix
//
// Sets may combine literals and ranges, e.g. '[a-zA-Z0-9_]'.
// A literal ']' inside a single-char class must be the first content character:
// '[]abc]' matches ']', 'a', 'b' or 'c'.  '[!]abc]' negates the same set.
// A '-' that is the first or last content character is treated as a literal,
// e.g. '[-x]' matches '-' or 'x'; '[a-]' matches 'a' or '-'.
//
// Two flavours of '[...]':
//
//   Single-char class: '[abc]', '[a-z]', '[!xyz]' - matches exactly one input
//   character.  This is the legacy DOS form.
//
//   Quoted-string alternation: '["foo"|"bar"|"baz"]' - matches one of the
//   listed literal strings at the current position and consumes its length.
//   '|' inside the brackets is the alternative separator.  Auto-detected:
//   if the first content character (after an optional '!') is '"', the
//   class is parsed in alternation form; otherwise the legacy single-char
//   rules apply.
//
//   Negated alternation '[!"foo"|"bar"]' succeeds when NONE of the listed
//   alternatives is a prefix at the current position; it then consumes the
//   length of the LONGEST alternative.  When the input has fewer characters
//   left than the longest alternative, the match fails (just like the
//   positive form would when there is not enough input to span the alt).
//
//   Empty quoted alternative ('""') is allowed and matches zero characters
//   (always succeeds, consumes nothing).  Backslashes / quote escapes are
//   NOT supported - quoted alternation is intended for file-mask use and
//   Windows file names cannot contain the characters '[', ']', '|' or '"'
//   to begin with, so the syntax stays safe to embed in literal masks.
//
//   '"' OUTSIDE a '[...]' class is a plain literal character.
//
// Matching is case-insensitive by default (Windows convention); pass
// ACaseSensitive = True for ordinal comparison.  The case-sensitive and
// case-insensitive engines are separate code paths - no per-character
// branch on the flag - so case-sensitive matching is noticeably faster.
//
// The CI engine pre-upper-cases the pattern once (cheap, patterns are
// small and scanned many times during backtracking) so the inner loop
// only has to upper-case the input side.  Upper-casing uses an inline
// ASCII fast path with a Unicode fallback for chars >= U+0080, so
// non-ASCII letters (e.g. Finnish 'å'/'Å') still compare correctly.
//
// The multi-pattern overloads return True on the first pattern that matches
// (short-circuit) and do not report which one - keep the call site simple.
//
// TWildCard can also be used as an instance value (record) that COMPILES
// a set of patterns at construction time into token programs: literal runs
// become block compares, classes and quoted alternations are parsed once,
// and every token knows the minimum input length the rest of the pattern
// needs (used to prune '*' scans and reject too-short inputs outright).
// This is the fast path - use it whenever the same pattern set is matched
// against many inputs.  Case-sensitivity is locked in at Create and used
// for every Match call on that instance.  Patterns come first,
// ACaseSensitive last with default False, e.g.
//   var LMask := TWildCard.Create(['*.pas', '*.dpr']);            // CI
//   var LSrc  := TWildCard.Create(['*.pas', '*.dpr'], True);      // CS
//   for var LFile in TDirectory.GetFiles(...) do
//     if LMask.Match(LFile) then ...
// Instance Match(input, pattern) calls use the ad-hoc pattern only by
// default; pass AAlsoMatchRegistered = True to also try the registered set.

// SIMD selection: the SSE2-accelerated scan kernels for the '*' skip
// loops (the hottest loops in backtracking-heavy patterns) are the
// DEFAULT.  Define PUREPASCAL (project option or -DPUREPASCAL) to opt out
// and compile the plain pascal loops instead - for builds that must run
// on very old CPUs.  No runtime CPU detection - the choice is static.
//
// Each accelerated code block is guarded by instruction set AND platform,
// e.g. {$IF Defined(USE_SSE2) and Defined(WIN32)}.  This leaves room for
// separate Win64 blocks (x64 asm differs) without touching the call
// sites' structure.  Targets with no matching block compile the pure
// pascal path regardless of defines.
//
// SSE2 is deliberate and sufficient - newer instruction sets would NOT
// bring significant gains for this workload:
//   - SSE4.2's own string instructions (PCMPISTRI) have HIGHER latency
//     than the plain PCMPEQW + PMOVMSKB sequence used here.
//   - AVX2 (16 chars per step instead of 8) only pays off on long scans;
//     file-mask inputs break at '\' every 8-25 chars, so the per-call
//     fixed cost (setup, tail, candidate verification) dominates and the
//     estimated ceiling is ~0-10% on the worst-case scenario, ~0%
//     elsewhere - while adding VZEROUPPER transition costs.  Revisit only
//     if the matcher is ever pointed at long inputs (file contents,
//     multi-KB strings), where wider vectors would see a real 1.5-1.8x
//     on the scan portion.
{$IFNDEF PUREPASCAL}
  {$DEFINE USE_SSE2}
{$ENDIF}

interface

uses
  System.Classes;

type
  TWildCard = record
  strict private
  type
    // === Compiled pattern representation ===
    // Registered patterns are compiled ONCE at Create into a token array,
    // so matching never re-scans the pattern text for class bounds,
    // alternation spans or literal runs.  Ad-hoc Match(input, pattern)
    // calls still use the interpreting engine (MatchRecursiveCS/CI) -
    // per-call compilation would cost more than it saves for one-shots.
    TTokenKind = (tkLiteral, tkStar, tkAnyChar, tkDigit, tkCharClass, tkAltGroup);

    TCharRange = record
      Lo, Hi: Char;
    end;

    TToken = record
      Kind: TTokenKind;
      Lit: string;                  // tkLiteral: the literal run
      Negate: Boolean;              // tkCharClass / tkAltGroup
      Singles: string;              // tkCharClass: single member chars
      Ranges: TArray<TCharRange>;   // tkCharClass: lo..hi ranges
      Alts: TArray<string>;         // tkAltGroup: alternatives (may contain '')
      MaxAltLen: Integer;           // tkAltGroup: longest alternative
      MinAltLen: Integer;           // tkAltGroup: shortest alternative
      MinRemain: Integer;           // min input chars needed from this token to pattern end
    end;
    PToken = ^TToken;

    TCompiledPattern = record
      Tokens: TArray<TToken>;
      Valid: Boolean;               // False = malformed pattern, never matches
    end;

  var
    // Instance state - set by Create overloads, used by instance Match.
    // Always go through one of the Create overloads (or Default(TWildCard))
    // to initialise - a bare 'var LMask: TWildCard' leaves FCaseSensitive
    // with stack garbage because Boolean is an unmanaged type.
    FPatterns: TArray<string>;            // pre-upper-cased if CI, originals if CS
    FCompiled: TArray<TCompiledPattern>;  // compiled at Create, one per pattern
    FCaseSensitive: Boolean;
    // Case-independent helpers
    class function IsAsciiDigit(const AChar: Char): Boolean; static; inline;
    class function FindClassEnd(const APattern: string; const AStart: Integer; var AIsQuotedAlt: Boolean): Integer; static;
    class function PatternTailIsLiteral(const APattern: string; const APatternIdx: Integer): Boolean; static;
    // Compiled engine (registered patterns).  The pattern text handed to
    // CompilePattern must already be prepared (upper-cased for CI).
    class procedure AddToken(const AToken: TToken; var ATokens: TArray<TToken>; var ACount: Integer); static;
    class procedure FlushLiteralToken(const APattern: string; const AEndExclusive, ALitStart: Integer;
      var ATokens: TArray<TToken>; var ACount: Integer); static;
    class function ParseClassToken(const APattern: string; var AClassIdx: Integer; var AToken: TToken;
      const ALen: Integer): Boolean; static;
    class function CompilePattern(const APattern: string): TCompiledPattern; static;
    class function CharInCompiledClass(const AToken: TToken; const AChar: Char): Boolean; static;
    class function LiteralMatchesAtCI(const AInput: string; const AInputIdx: Integer; const ALit: string): Boolean; static;
    class function MatchTokensCS(const ATokens: TArray<TToken>; const AInput: string; AInputIdx, ATokenIdx: Integer): Boolean; static;
    class function MatchTokensCI(const ATokens: TArray<TToken>; const AInput: string; AInputIdx, ATokenIdx: Integer): Boolean; static;
    function MatchCompiled(const ACompiled: TCompiledPattern; const AInput: string): Boolean;
    // Case-sensitive path (direct ordinal compare, no ToUpper calls)
    class function CharInClassCS(const APattern: string; const AStart, AEnd: Integer; const AChar: Char): Boolean; static;
    class function AltMatchesAtCS(const AInput: string; const AInputIdx: Integer;
      const APattern: string; const AAltStart, AAltLen: Integer): Boolean; static;
    class function MatchQuotedAltClassCS(const AInput, APattern: string;
      const AInputIdx, AClassStart, AClassEnd: Integer): Boolean; static;
    class function MatchRecursiveCS(const AInput, APattern: string; AInputIdx, APatternIdx: Integer): Boolean; static;
    // Case-insensitive path (ToUpper compare)
    class function CharInClassCI(const APattern: string; const AStart, AEnd: Integer; const AChar: Char): Boolean; static;
    class function AltMatchesAtCI(const AInput: string; const AInputIdx: Integer;
      const APattern: string; const AAltStart, AAltLen: Integer): Boolean; static;
    class function MatchQuotedAltClassCI(const AInput, APattern: string;
      const AInputIdx, AClassStart, AClassEnd: Integer): Boolean; static;
    class function MatchRecursiveCI(const AInput, APattern: string; AInputIdx, APatternIdx: Integer): Boolean; static;
    // Walks FPatterns and returns True on the first match.  FPatterns are
    // already in the correct form (pre-upper-cased for CI), so no per-call
    // FastUpperString work is needed here.
    function MatchRegistered(const AInput: string): Boolean;
  public
    // === Instance API: pre-register patterns + match many inputs ===
    // ACaseSensitive is locked in for the lifetime of the instance and
    // defaults to case-insensitive matching (Windows convention).
    // For one-off matching (no pre-registered patterns) use the no-arg
    // Create overload directly, e.g.
    //   if TWildCard.Create.Match(LFile, '*.pas') then ...
    //   if TWildCard.Create(True).Match('CASE.txt', '*.txt') then ...
    //   if TWildCard.Create.Match(LFile, ['*.pas', '*.dpr']) then ...
    class function Create(const ACaseSensitive: Boolean = False): TWildCard; overload; static;
    class function Create(const APattern: string; const ACaseSensitive: Boolean = False): TWildCard; overload; static;
    class function Create(const APatterns: TArray<string>; const ACaseSensitive: Boolean = False): TWildCard; overload; static;
    class function Create(const APatterns: TStrings; const ACaseSensitive: Boolean = False): TWildCard; overload; static;

    // Match against the registered set only.
    function Match(const AInput: string): Boolean; overload;
    // Match against an ad-hoc pattern (uses the instance's case mode). AAlsoMatchRegistered = True also tries the registered set.
    function Match(const AInput, APattern: string; const AAlsoMatchRegistered: Boolean = False): Boolean; overload;
    function Match(const AInput: string; const APatterns: TArray<string>; const AAlsoMatchRegistered: Boolean = False): Boolean; overload;
    function Match(const AInput: string; const APatterns: TStrings; const AAlsoMatchRegistered: Boolean = False): Boolean; overload;
    property CaseSensitive: Boolean read FCaseSensitive;
    property RegisteredPatterns: TArray<string> read FPatterns;
  end;

  // Include / exclude filter built from two TWildCard matchers.
  //
  // An input is accepted when it matches the INCLUDE list AND does not
  // match the EXCLUDE list, with the usual filtering conventions:
  //   - empty include list  = everything is included (the include list
  //     only restricts when it has patterns)
  //   - empty exclude list  = nothing is excluded
  //   - both lists empty    = everything is accepted
  //   - exclude always wins over include
  //
  // Patterns are compiled at Create (both lists are registered-pattern
  // TWildCard instances), so Accepts is cheap to call in a loop:
  //
  //   var LFilter := TWildCardFilter.Create(
  //     ['*.pas', '*.dpr', '*.inc'],                  // filter in
  //     ['*\__history\*', '*backup*', '*.tmp']);      // filter out
  //   for var LFile in TDirectory.GetFiles(ARoot) do
  //     if LFilter.Accepts(LFile) then
  //       ProcessFile(LFile);
  //
  // Case-sensitivity is locked in at Create for BOTH lists and defaults
  // to case-insensitive (Windows convention).  As with TWildCard, always
  // initialise through a Create overload or Default(TWildCardFilter) -
  // the default state accepts everything.
  TWildCardFilter = record
  strict private
    FInclude: TWildCard;
    FExclude: TWildCard;
    FHasIncludes: Boolean;
    FCaseSensitive: Boolean;
    function GetIncludePatterns: TArray<string>;
    function GetExcludePatterns: TArray<string>;
  public
    class function Create(const ACaseSensitive: Boolean = False): TWildCardFilter; overload; static;
    class function Create(const AIncludePattern, AExcludePattern: string; const ACaseSensitive: Boolean = False): TWildCardFilter;
      overload; static;
    class function Create(const AIncludePatterns, AExcludePatterns: TArray<string>; const ACaseSensitive: Boolean = False): TWildCardFilter;
      overload; static;
    // TStrings overload tolerates nil for either list (treated as empty).
    class function Create(const AIncludePatterns, AExcludePatterns: TStrings; const ACaseSensitive: Boolean = False): TWildCardFilter;
      overload; static;

    // True when AInput passes the include stage and is not excluded.
    function Accepts(const AInput: string): Boolean;

    property CaseSensitive: Boolean read FCaseSensitive;
    property IncludePatterns: TArray<string> read GetIncludePatterns;
    property ExcludePatterns: TArray<string> read GetExcludePatterns;
  end;

implementation

uses
  System.Character, System.SysUtils;

{ TWildCard - shared helpers }

// Inline ASCII fast path for ToUpper.  ASCII a..z is a single subtract;
// everything else < U+0080 returns unchanged; only chars >= U+0080 fall
// back to System.Character's Char.ToUpper - a Unicode-table lookup with
// NO heap allocation.  (The previous AnsiUpperCase(AChar)[1] built a
// temporary string per call, which is brutal inside the backtracking
// inner loop.)  Char.ToUpper uses invariant simple case mappings, so
// 'ä'/'å'/'ü'/Cyrillic/Greek all round-trip correctly; only locale-special
// mappings (e.g. Turkish dotless i) differ from the old locale-aware
// LCMapStringW behaviour.  System.SysUtils.UpperCase is ASCII-only - it
// does NOT upper-case 'ä'/'å'/'ü' etc. - so it is not an option here.
//
// NOTE: we compare via Ord() instead of 'AChar < #128'.  Char-literal
// #128 is parsed as AnsiChar; comparing WideChar to AnsiChar goes through
// a signed-byte path where e.g. WideChar(228) < AnsiChar(128) evaluates
// to True (228 as signed byte = -28).  Ord() forces unsigned Integer
// comparison which is correct.
function FastToUpper(const AChar: Char): Char; inline;
begin
  if (AChar >= 'a') and (AChar <= 'z') then
    Result := Chr(Ord(AChar) - 32)
  else if Ord(AChar) < 128 then
    Result := AChar
  else
    Result := AChar.ToUpper;
end;

function FastUpperString(const AStr: string): string;
var
  LIdx, LFirst, LLen: Integer;
  LChar: Char;
begin
  // Single pass: scan for the first char FastToUpper would change (ASCII
  // lowercase or any non-ASCII).  If there is none - common for patterns
  // like '*' or 'FOO*.PAS' - return the original string with no allocation.
  LLen := Length(AStr);
  LFirst := 0;

  for LIdx := 1 to LLen do
  begin
    LChar := AStr[LIdx];

    if ((LChar >= 'a') and (LChar <= 'z')) or (Ord(LChar) >= 128) then
    begin
      LFirst := LIdx;
      Break;
    end;
  end;

  if LFirst = 0 then
    Exit(AStr);

  // Allocate once, block-copy the already-clean prefix, convert the rest.
  SetLength(Result, LLen);

  if LFirst > 1 then
    Move(AStr[1], Result[1], (LFirst - 1) * SizeOf(Char));

  for LIdx := LFirst to LLen do
  begin
    LChar := AStr[LIdx];

    if (LChar >= 'a') and (LChar <= 'z') then
      Result[LIdx] := Chr(Ord(LChar) - 32)
    else if Ord(LChar) < 128 then
      Result[LIdx] := LChar
    else
      Result[LIdx] := LChar.ToUpper;
  end;
end;

{ TWildCard }

{$IF Defined(USE_SSE2) and Defined(WIN32)}
// SSE scan kernels for the '*' skip loops (Win32).  Both process 8 UTF-16
// chars per iteration with a scalar tail.
//
// ScanCharIndex: 0-based index of the first occurrence of AChar in
// AText[0..ACount-1], or -1 when not present.  Exact (case-sensitive)
// match - the caller can recurse directly on a hit.
function ScanCharIndex(AText: PChar; ACount: Integer; AChar: Char): Integer;
asm
  // EAX = AText, EDX = ACount, ECX = AChar
  PUSH      EBX
  MOVD      XMM1, ECX
  PUNPCKLWD XMM1, XMM1
  PSHUFD    XMM1, XMM1, 0
  XOR       EBX, EBX            // running char index
@@Loop8:
  CMP       EDX, 8
  JL        @@Tail
  MOVDQU    XMM0, [EAX]
  PCMPEQW   XMM0, XMM1
  PMOVMSKB  ECX, XMM0
  TEST      ECX, ECX
  JNZ       @@Found
  ADD       EAX, 16
  ADD       EBX, 8
  SUB       EDX, 8
  JMP       @@Loop8
@@Found:
  BSF       ECX, ECX
  SHR       ECX, 1              // byte offset -> char offset
  LEA       EAX, [EBX+ECX]
  JMP       @@Done
@@Tail:
  MOVD      ECX, XMM1           // recover AChar in CX
@@TailLoop:
  TEST      EDX, EDX
  JZ        @@NotFound
  CMP       WORD PTR [EAX], CX
  JE        @@TailFound
  ADD       EAX, 2
  INC       EBX
  DEC       EDX
  JMP       @@TailLoop
@@TailFound:
  MOV       EAX, EBX
  JMP       @@Done
@@NotFound:
  MOV       EAX, -1
@@Done:
  POP       EBX
end;

// ScanCharIndexCI: 0-based index of the first CANDIDATE position in
// AText[0..ACount-1], or -1.  AChars packs the pre-upper-cased pattern
// char in the LOW word and its ASCII-lowercase variant in the HIGH word.
// A candidate is a char equal to either variant, or ANY char >= U+0080
// (non-ASCII needs the scalar Unicode ToUpper check - e.g. U+017F upper-
// cases to 'S', which a two-value compare would miss).  The caller MUST
// re-verify the candidate with the scalar test before recursing.
function ScanCharIndexCI(AText: PChar; ACount: Integer; AChars: Cardinal): Integer;
asm
  // EAX = AText, EDX = ACount, ECX = AChars (low = upper, high = lower)
  PUSH      EBX
  PUSH      ESI
  PUSH      EDI
  MOVZX     ESI, CX             // upper variant
  MOV       EDI, ECX
  SHR       EDI, 16             // lower variant
  MOVD      XMM1, ESI
  PUNPCKLWD XMM1, XMM1
  PSHUFD    XMM1, XMM1, 0
  MOVD      XMM2, EDI
  PUNPCKLWD XMM2, XMM2
  PSHUFD    XMM2, XMM2, 0
  PCMPEQW   XMM6, XMM6          // all ones
  MOVDQA    XMM7, XMM6
  PSLLW     XMM7, 7             // $FF80 per lane (non-ASCII bits)
  PXOR      XMM5, XMM5
  XOR       EBX, EBX            // running char index
@@Loop8:
  CMP       EDX, 8
  JL        @@TailLoop
  MOVDQU    XMM0, [EAX]
  MOVDQA    XMM3, XMM0
  MOVDQA    XMM4, XMM0
  PCMPEQW   XMM3, XMM1          // = upper variant
  PCMPEQW   XMM4, XMM2          // = lower variant
  POR       XMM3, XMM4
  PAND      XMM0, XMM7          // isolate non-ASCII bits
  PCMPEQW   XMM0, XMM5          // FFFF where ASCII
  PANDN     XMM0, XMM6          // FFFF where non-ASCII
  POR       XMM3, XMM0          // matches OR non-ASCII candidates
  PMOVMSKB  ECX, XMM3
  TEST      ECX, ECX
  JNZ       @@Found
  ADD       EAX, 16
  ADD       EBX, 8
  SUB       EDX, 8
  JMP       @@Loop8
@@Found:
  BSF       ECX, ECX
  SHR       ECX, 1
  LEA       EAX, [EBX+ECX]
  JMP       @@Done
@@TailLoop:
  TEST      EDX, EDX
  JZ        @@NotFound
  MOVZX     ECX, WORD PTR [EAX]
  CMP       ECX, $0080
  JAE       @@Hit               // non-ASCII -> candidate
  CMP       ECX, ESI
  JE        @@Hit
  CMP       ECX, EDI
  JE        @@Hit
  ADD       EAX, 2
  INC       EBX
  DEC       EDX
  JMP       @@TailLoop
@@Hit:
  MOV       EAX, EBX
  JMP       @@Done
@@NotFound:
  MOV       EAX, -1
@@Done:
  POP       EDI
  POP       ESI
  POP       EBX
end;
{$ENDIF}

class function TWildCard.IsAsciiDigit(const AChar: Char): Boolean;
begin
  Result := (AChar >= '0') and (AChar <= '9');
end;

class function TWildCard.FindClassEnd(const APattern: string; const AStart: Integer; var AIsQuotedAlt: Boolean): Integer;
var
  LIndex: Integer;
  LPatternLen: Integer;
begin
  // AStart points at '['. Returns index of ']' that closes the class, or 0
  // if the class is unterminated.  AIsQuotedAlt reports whether the class
  // is in quoted-alternation form (first content char after an optional
  // '!' is '"') - returned from here so the caller does not have to
  // re-scan the class prefix to find out.
  //
  // Two scanning modes:
  //   Legacy single-char class: leading ']' is treated as a literal so
  //     '[]abc]' is a valid class containing ']abc'.
  //   Quoted-alternation class: ']' inside a '"..."' span is part of the
  //     alternative literal and does NOT close the class.  An unterminated
  //     '"' (no closing quote before end of pattern) makes the class
  //     malformed (returns 0).
  LPatternLen := Length(APattern);
  LIndex := AStart + 1;

  if (LIndex <= LPatternLen) and (APattern[LIndex] = '!') then
    Inc(LIndex);

  AIsQuotedAlt := (LIndex <= LPatternLen) and (APattern[LIndex] = '"');

  if (not AIsQuotedAlt) and (LIndex <= LPatternLen) and (APattern[LIndex] = ']') then
    Inc(LIndex);

  while LIndex <= LPatternLen do
  begin
    if AIsQuotedAlt and (APattern[LIndex] = '"') then
    begin
      // Skip past the alternative's content to the closing '"'.
      Inc(LIndex);

      while (LIndex <= LPatternLen) and (APattern[LIndex] <> '"') do
        Inc(LIndex);

      if LIndex > LPatternLen then
        Exit(0);

      Inc(LIndex);
      Continue;
    end;

    if APattern[LIndex] = ']' then
      Exit(LIndex);

    Inc(LIndex);
  end;

  Result := 0;
end;

class function TWildCard.PatternTailIsLiteral(const APattern: string; const APatternIdx: Integer): Boolean;
var
  LIdx: Integer;
begin
  // True when the pattern from APatternIdx to the end contains no
  // metacharacters, i.e. it is a plain literal suffix.  Lets the '*'
  // handler anchor the compare at the END of the input - the dominant
  // '*.ext' file-mask shape - instead of recursing at every start
  // position.
  for LIdx := APatternIdx to Length(APattern) do
    case APattern[LIdx] of
      '*', '?', '#', '[':
        Exit(False);
    end;

  Result := True;
end;

{ TWildCard - case-sensitive path }

class function TWildCard.CharInClassCS(const APattern: string; const AStart, AEnd: Integer; const AChar: Char): Boolean;
var
  LIndex: Integer;
  LNegate: Boolean;
begin
  LIndex := AStart + 1;
  LNegate := False;

  if APattern[LIndex] = '!' then
  begin
    LNegate := True;
    Inc(LIndex);
  end;

  Result := False;

  while LIndex < AEnd do
  begin
    // 'X-Y' is a range when '-' is followed by a real content character.
    // When '-' is the last content character (next position is the closing
    // ']'), it is treated as a literal.
    if (LIndex + 2 < AEnd) and (APattern[LIndex + 1] = '-') then
    begin
      if (AChar >= APattern[LIndex]) and (AChar <= APattern[LIndex + 2]) then
        Result := True;

      Inc(LIndex, 3);
    end
    else
    begin
      if AChar = APattern[LIndex] then
        Result := True;

      Inc(LIndex);
    end;
  end;

  if LNegate then
    Result := not Result;
end;

class function TWildCard.AltMatchesAtCS(const AInput: string; const AInputIdx: Integer; const APattern: string; const AAltStart,
  AAltLen: Integer): Boolean;
var
  LIdx: Integer;
begin
  // Empty alternative ('""') matches zero characters - always True.
  if AAltLen = 0 then
    Exit(True);

  if AInputIdx + AAltLen - 1 > Length(AInput) then
    Exit(False);

  for LIdx := 0 to AAltLen - 1 do
    if AInput[AInputIdx + LIdx] <> APattern[AAltStart + LIdx] then
      Exit(False);

  Result := True;
end;

class function TWildCard.MatchQuotedAltClassCS(const AInput, APattern: string; const AInputIdx, AClassStart, AClassEnd: Integer): Boolean;
var
  LIdx: Integer;
  LNegated: Boolean;
  LAfterClass: Integer;
  LAltStart, LAltLen: Integer;
  LAltContentEnd: Integer;
  LAfterAlt: Integer;
  LMaxLen: Integer;
begin
  // AClassStart points at '[', AClassEnd at the closing ']'.  Iterates the
  // alternatives, recursing into MatchRecursiveCS on the remainder of the
  // pattern for each.  For the negated form, the longest alternative
  // dictates how much input the class consumes when it succeeds.
  //
  // Note: the separator check is done BEFORE attempting to match an alt,
  // so a malformed class (missing '|' between alts, stray garbage) fails
  // unconditionally regardless of what the first alt would have matched.
  LIdx := AClassStart + 1;
  LNegated := APattern[LIdx] = '!';

  if LNegated then
    Inc(LIdx);

  LAfterClass := AClassEnd + 1;

  if not LNegated then
  begin
    while LIdx < AClassEnd do
    begin
      if APattern[LIdx] <> '"' then
        Exit(False);

      LAltStart := LIdx + 1;
      LAltContentEnd := LAltStart;

      while (LAltContentEnd < AClassEnd) and (APattern[LAltContentEnd] <> '"') do
        Inc(LAltContentEnd);

      if LAltContentEnd >= AClassEnd then
        Exit(False);

      LAltLen := LAltContentEnd - LAltStart;
      LAfterAlt := LAltContentEnd + 1;

      if (LAfterAlt < AClassEnd) and (APattern[LAfterAlt] <> '|') then
        Exit(False);

      if AltMatchesAtCS(AInput, AInputIdx, APattern, LAltStart, LAltLen) then
        if MatchRecursiveCS(AInput, APattern, AInputIdx + LAltLen, LAfterClass) then
          Exit(True);

      if LAfterAlt < AClassEnd then
        LIdx := LAfterAlt + 1
      else
        LIdx := LAfterAlt;
    end;

    Result := False;
  end
  else
  begin
    LMaxLen := 0;

    while LIdx < AClassEnd do
    begin
      if APattern[LIdx] <> '"' then
        Exit(False);

      LAltStart := LIdx + 1;
      LAltContentEnd := LAltStart;

      while (LAltContentEnd < AClassEnd) and (APattern[LAltContentEnd] <> '"') do
        Inc(LAltContentEnd);

      if LAltContentEnd >= AClassEnd then
        Exit(False);

      LAltLen := LAltContentEnd - LAltStart;
      LAfterAlt := LAltContentEnd + 1;

      if (LAfterAlt < AClassEnd) and (APattern[LAfterAlt] <> '|') then
        Exit(False);

      if LAltLen > LMaxLen then
        LMaxLen := LAltLen;

      // Any alternative matching as a prefix fails the negation - and a
      // malformed remainder would return False anyway, so bail right away
      // instead of scanning the remaining alternatives.
      if AltMatchesAtCS(AInput, AInputIdx, APattern, LAltStart, LAltLen) then
        Exit(False);

      if LAfterAlt < AClassEnd then
        LIdx := LAfterAlt + 1
      else
        LIdx := LAfterAlt;
    end;

    if (LMaxLen > 0) and (AInputIdx + LMaxLen - 1 > Length(AInput)) then
      Exit(False);

    Result := MatchRecursiveCS(AInput, APattern, AInputIdx + LMaxLen, LAfterClass);
  end;
end;

class function TWildCard.MatchRecursiveCS(const AInput, APattern: string; AInputIdx, APatternIdx: Integer): Boolean;
var
  LClassEnd: Integer;
  LIsQuotedAlt: Boolean;
  LInputLen, LPatternLen: Integer;
  LTailLen, LTailStart, LIdx: Integer;
  LNextChar: Char;
{$IF Defined(USE_SSE2) and Defined(WIN32)}
  LRel: Integer;
{$ENDIF}
begin
  LInputLen := Length(AInput);
  LPatternLen := Length(APattern);

  while APatternIdx <= LPatternLen do
  begin
    case APattern[APatternIdx] of
      '*':
        begin
          while (APatternIdx <= LPatternLen) and (APattern[APatternIdx] = '*') do
            Inc(APatternIdx);

          if APatternIdx > LPatternLen then
            Exit(True);

          // Fast path 1: the rest of the pattern is a plain literal - the
          // dominant '*.ext' file-mask shape.  Anchor the compare at the
          // END of the input: one comparison instead of one recursion per
          // start position.
          if PatternTailIsLiteral(APattern, APatternIdx) then
          begin
            LTailLen := LPatternLen - APatternIdx + 1;
            LTailStart := LInputLen - LTailLen + 1;

            if LTailStart < AInputIdx then
              Exit(False);

            for LIdx := 0 to LTailLen - 1 do
              if AInput[LTailStart + LIdx] <> APattern[APatternIdx + LIdx] then
                Exit(False);

            Exit(True);
          end;

          // Fast path 2: only recurse at input positions where the token
          // right after the '*' can actually match, instead of at every
          // position.
          LNextChar := APattern[APatternIdx];

          case LNextChar of
            '?':
              begin
                // '?' consumes one char, so any position with input left
                // is a candidate - but end-of-input is not.
                while AInputIdx <= LInputLen do
                begin
                  if MatchRecursiveCS(AInput, APattern, AInputIdx, APatternIdx) then
                    Exit(True);

                  Inc(AInputIdx);
                end;
              end;
            '#':
              begin
                while AInputIdx <= LInputLen do
                begin
                  if IsAsciiDigit(AInput[AInputIdx]) then
                    if MatchRecursiveCS(AInput, APattern, AInputIdx, APatternIdx) then
                      Exit(True);

                  Inc(AInputIdx);
                end;
              end;
            '[':
              begin
                // Classes need full evaluation - and a quoted-alt class
                // with an empty alternative can match zero chars - so try
                // every position INCLUDING the end-of-input one.
                while AInputIdx <= LInputLen + 1 do
                begin
                  if MatchRecursiveCS(AInput, APattern, AInputIdx, APatternIdx) then
                    Exit(True);

                  Inc(AInputIdx);
                end;
              end;
          else
            // Plain literal - skip straight to positions where it occurs.
{$IF Defined(USE_SSE2) and Defined(WIN32)}
            while AInputIdx <= LInputLen do
            begin
              LRel := ScanCharIndex(PChar(Pointer(AInput)) + AInputIdx - 1, LInputLen - AInputIdx + 1, LNextChar);
              if LRel < 0 then
                Break;

              Inc(AInputIdx, LRel);

              if MatchRecursiveCS(AInput, APattern, AInputIdx, APatternIdx) then
                Exit(True);

              Inc(AInputIdx);
            end;
{$ELSE}
            while AInputIdx <= LInputLen do
            begin
              if AInput[AInputIdx] = LNextChar then
                if MatchRecursiveCS(AInput, APattern, AInputIdx, APatternIdx) then
                  Exit(True);

              Inc(AInputIdx);
            end;
{$ENDIF}
          end;

          Exit(False);
        end;
      '?':
        begin
          if AInputIdx > LInputLen then
            Exit(False);

          Inc(AInputIdx);
          Inc(APatternIdx);
        end;
      '#':
        begin
          if AInputIdx > LInputLen then
            Exit(False);

          if not IsAsciiDigit(AInput[AInputIdx]) then
            Exit(False);

          Inc(AInputIdx);
          Inc(APatternIdx);
        end;
      '[':
        begin
          LClassEnd := FindClassEnd(APattern, APatternIdx, LIsQuotedAlt);
          if LClassEnd = 0 then
            Exit(False);

          if LIsQuotedAlt then
            Exit(MatchQuotedAltClassCS(AInput, APattern, AInputIdx, APatternIdx, LClassEnd));

          if AInputIdx > LInputLen then
            Exit(False);

          if not CharInClassCS(APattern, APatternIdx, LClassEnd, AInput[AInputIdx]) then
            Exit(False);

          Inc(AInputIdx);
          APatternIdx := LClassEnd + 1;
        end;
    else
      begin
        if AInputIdx > LInputLen then
          Exit(False);

        if AInput[AInputIdx] <> APattern[APatternIdx] then
          Exit(False);

        Inc(AInputIdx);
        Inc(APatternIdx);
      end;
    end;
  end;

  Result := AInputIdx > LInputLen;
end;

{ TWildCard - case-insensitive path }

class function TWildCard.CharInClassCI(const APattern: string; const AStart, AEnd: Integer; const AChar: Char): Boolean;
var
  LIndex: Integer;
  LNegate: Boolean;
  LCharUpper: Char;
begin
  // Pattern is pre-upper-cased by the public Match dispatcher, so the
  // pattern-side chars need no conversion here.  Only the input char
  // is upper-cased - once, outside the class-walk loop.
  LCharUpper := FastToUpper(AChar);

  LIndex := AStart + 1;
  LNegate := False;

  if APattern[LIndex] = '!' then
  begin
    LNegate := True;
    Inc(LIndex);
  end;

  Result := False;

  while LIndex < AEnd do
  begin
    if (LIndex + 2 < AEnd) and (APattern[LIndex + 1] = '-') then
    begin
      if (LCharUpper >= APattern[LIndex]) and (LCharUpper <= APattern[LIndex + 2]) then
        Result := True;

      Inc(LIndex, 3);
    end
    else
    begin
      if LCharUpper = APattern[LIndex] then
        Result := True;

      Inc(LIndex);
    end;
  end;

  if LNegate then
    Result := not Result;
end;

class function TWildCard.AltMatchesAtCI(const AInput: string; const AInputIdx: Integer; const APattern: string; const AAltStart,
  AAltLen: Integer): Boolean;
var
  LIdx: Integer;
begin
  // Pattern alt content is pre-upper-cased by the public Match dispatcher,
  // so only the input side needs FastToUpper here - and only when the
  // direct ordinal compare misses.
  if AAltLen = 0 then
    Exit(True);

  if AInputIdx + AAltLen - 1 > Length(AInput) then
    Exit(False);

  for LIdx := 0 to AAltLen - 1 do
    if (AInput[AInputIdx + LIdx] <> APattern[AAltStart + LIdx]) and (FastToUpper(AInput[AInputIdx + LIdx]) <> APattern[AAltStart + LIdx]) then
      Exit(False);

  Result := True;
end;

class function TWildCard.MatchQuotedAltClassCI(const AInput, APattern: string; const AInputIdx, AClassStart, AClassEnd: Integer): Boolean;
var
  LIdx: Integer;
  LNegated: Boolean;
  LAfterClass: Integer;
  LAltStart, LAltLen: Integer;
  LAltContentEnd: Integer;
  LAfterAlt: Integer;
  LMaxLen: Integer;
begin
  // See the CS variant for the matching/validation rules - the only
  // difference is the per-character upper-casing on the input side.
  LIdx := AClassStart + 1;
  LNegated := APattern[LIdx] = '!';

  if LNegated then
    Inc(LIdx);

  LAfterClass := AClassEnd + 1;

  if not LNegated then
  begin
    while LIdx < AClassEnd do
    begin
      if APattern[LIdx] <> '"' then
        Exit(False);

      LAltStart := LIdx + 1;
      LAltContentEnd := LAltStart;

      while (LAltContentEnd < AClassEnd) and (APattern[LAltContentEnd] <> '"') do
        Inc(LAltContentEnd);

      if LAltContentEnd >= AClassEnd then
        Exit(False);

      LAltLen := LAltContentEnd - LAltStart;
      LAfterAlt := LAltContentEnd + 1;

      if (LAfterAlt < AClassEnd) and (APattern[LAfterAlt] <> '|') then
        Exit(False);

      if AltMatchesAtCI(AInput, AInputIdx, APattern, LAltStart, LAltLen) then
        if MatchRecursiveCI(AInput, APattern, AInputIdx + LAltLen, LAfterClass) then
          Exit(True);

      if LAfterAlt < AClassEnd then
        LIdx := LAfterAlt + 1
      else
        LIdx := LAfterAlt;
    end;

    Result := False;
  end
  else
  begin
    LMaxLen := 0;

    while LIdx < AClassEnd do
    begin
      if APattern[LIdx] <> '"' then
        Exit(False);

      LAltStart := LIdx + 1;
      LAltContentEnd := LAltStart;

      while (LAltContentEnd < AClassEnd) and (APattern[LAltContentEnd] <> '"') do
        Inc(LAltContentEnd);

      if LAltContentEnd >= AClassEnd then
        Exit(False);

      LAltLen := LAltContentEnd - LAltStart;
      LAfterAlt := LAltContentEnd + 1;

      if (LAfterAlt < AClassEnd) and (APattern[LAfterAlt] <> '|') then
        Exit(False);

      if LAltLen > LMaxLen then
        LMaxLen := LAltLen;

      // Any alternative matching as a prefix fails the negation - and a
      // malformed remainder would return False anyway, so bail right away
      // instead of scanning the remaining alternatives.
      if AltMatchesAtCI(AInput, AInputIdx, APattern, LAltStart, LAltLen) then
        Exit(False);

      if LAfterAlt < AClassEnd then
        LIdx := LAfterAlt + 1
      else
        LIdx := LAfterAlt;
    end;

    if (LMaxLen > 0) and (AInputIdx + LMaxLen - 1 > Length(AInput)) then
      Exit(False);

    Result := MatchRecursiveCI(AInput, APattern, AInputIdx + LMaxLen, LAfterClass);
  end;
end;

class function TWildCard.MatchRecursiveCI(const AInput, APattern: string; AInputIdx, APatternIdx: Integer): Boolean;
var
  LClassEnd: Integer;
  LIsQuotedAlt: Boolean;
  LInputLen, LPatternLen: Integer;
  LTailLen, LTailStart, LIdx: Integer;
  LNextChar: Char;
{$IF Defined(USE_SSE2) and Defined(WIN32)}
  LRel: Integer;
  LCharPair: Cardinal;
{$ENDIF}
begin
  LInputLen := Length(AInput);
  LPatternLen := Length(APattern);

  while APatternIdx <= LPatternLen do
  begin
    case APattern[APatternIdx] of
      '*':
        begin
          while (APatternIdx <= LPatternLen) and (APattern[APatternIdx] = '*') do
            Inc(APatternIdx);

          if APatternIdx > LPatternLen then
            Exit(True);

          // Fast path 1: the rest of the pattern is a plain literal - the
          // dominant '*.ext' file-mask shape.  Anchor the compare at the
          // END of the input: one comparison instead of one recursion per
          // start position.  Direct-equality precheck skips FastToUpper
          // for uppercase input and non-letters (dots, digits, '\').
          if PatternTailIsLiteral(APattern, APatternIdx) then
          begin
            LTailLen := LPatternLen - APatternIdx + 1;
            LTailStart := LInputLen - LTailLen + 1;

            if LTailStart < AInputIdx then
              Exit(False);

            for LIdx := 0 to LTailLen - 1 do
              if (AInput[LTailStart + LIdx] <> APattern[APatternIdx + LIdx]) and (FastToUpper(AInput[LTailStart + LIdx]) <> APattern[APatternIdx + LIdx]) then
                Exit(False);

            Exit(True);
          end;

          // Fast path 2: only recurse at input positions where the token
          // right after the '*' can actually match, instead of at every
          // position.
          LNextChar := APattern[APatternIdx];

          case LNextChar of
            '?':
              begin
                // '?' consumes one char, so any position with input left
                // is a candidate - but end-of-input is not.
                while AInputIdx <= LInputLen do
                begin
                  if MatchRecursiveCI(AInput, APattern, AInputIdx, APatternIdx) then
                    Exit(True);

                  Inc(AInputIdx);
                end;
              end;
            '#':
              begin
                while AInputIdx <= LInputLen do
                begin
                  if IsAsciiDigit(AInput[AInputIdx]) then
                    if MatchRecursiveCI(AInput, APattern, AInputIdx, APatternIdx) then
                      Exit(True);

                  Inc(AInputIdx);
                end;
              end;
            '[':
              begin
                // Classes need full evaluation - and a quoted-alt class
                // with an empty alternative can match zero chars - so try
                // every position INCLUDING the end-of-input one.
                while AInputIdx <= LInputLen + 1 do
                begin
                  if MatchRecursiveCI(AInput, APattern, AInputIdx, APatternIdx) then
                    Exit(True);

                  Inc(AInputIdx);
                end;
              end;
          else
            // Plain literal (pattern side is pre-upper-cased) - skip
            // straight to positions where it occurs.
{$IF Defined(USE_SSE2) and Defined(WIN32)}
            if (LNextChar >= 'A') and (LNextChar <= 'Z') then
              LCharPair := Cardinal(Ord(LNextChar)) or (Cardinal(Ord(LNextChar) + 32) shl 16)
            else
              LCharPair := Cardinal(Ord(LNextChar)) or (Cardinal(Ord(LNextChar)) shl 16);

            while AInputIdx <= LInputLen do
            begin
              LRel := ScanCharIndexCI(PChar(Pointer(AInput)) + AInputIdx - 1, LInputLen - AInputIdx + 1, LCharPair);
              if LRel < 0 then
                Break;

              Inc(AInputIdx, LRel);

              // Candidates include non-ASCII chars - re-verify before
              // recursing (see ScanCharIndexCI).
              if (AInput[AInputIdx] = LNextChar) or (FastToUpper(AInput[AInputIdx]) = LNextChar) then
                if MatchRecursiveCI(AInput, APattern, AInputIdx, APatternIdx) then
                  Exit(True);

              Inc(AInputIdx);
            end;
{$ELSE}
            while AInputIdx <= LInputLen do
            begin
              if (AInput[AInputIdx] = LNextChar) or (FastToUpper(AInput[AInputIdx]) = LNextChar) then
                if MatchRecursiveCI(AInput, APattern, AInputIdx, APatternIdx) then
                  Exit(True);

              Inc(AInputIdx);
            end;
{$ENDIF}
          end;

          Exit(False);
        end;
      '?':
        begin
          if AInputIdx > LInputLen then
            Exit(False);

          Inc(AInputIdx);
          Inc(APatternIdx);
        end;
      '#':
        begin
          if AInputIdx > LInputLen then
            Exit(False);

          if not IsAsciiDigit(AInput[AInputIdx]) then
            Exit(False);

          Inc(AInputIdx);
          Inc(APatternIdx);
        end;
      '[':
        begin
          LClassEnd := FindClassEnd(APattern, APatternIdx, LIsQuotedAlt);
          if LClassEnd = 0 then
            Exit(False);

          if LIsQuotedAlt then
            Exit(MatchQuotedAltClassCI(AInput, APattern, AInputIdx, APatternIdx, LClassEnd));

          if AInputIdx > LInputLen then
            Exit(False);

          if not CharInClassCI(APattern, APatternIdx, LClassEnd, AInput[AInputIdx]) then
            Exit(False);

          Inc(AInputIdx);
          APatternIdx := LClassEnd + 1;
        end;
    else
      begin
        if AInputIdx > LInputLen then
          Exit(False);

        // Pattern is pre-upper-cased; only upper-case the input side, and
        // only when the direct ordinal compare misses - uppercase input
        // and non-letters (dots, digits, path separators) hit the first
        // test and skip FastToUpper entirely.
        if (AInput[AInputIdx] <> APattern[APatternIdx]) and (FastToUpper(AInput[AInputIdx]) <> APattern[APatternIdx]) then
          Exit(False);

        Inc(AInputIdx);
        Inc(APatternIdx);
      end;
    end;
  end;

  Result := AInputIdx > LInputLen;
end;

{ TWildCard - compiled engine (registered patterns) }

class procedure TWildCard.AddToken(const AToken: TToken; var ATokens: TArray<TToken>; var ACount: Integer);
begin
  if ACount = Length(ATokens) then
    SetLength(ATokens, (ACount * 2) + 8);

  ATokens[ACount] := AToken;
  Inc(ACount);
end;

class procedure TWildCard.FlushLiteralToken(const APattern: string; const AEndExclusive, ALitStart: Integer;
  var ATokens: TArray<TToken>; var ACount: Integer);
var
  LLitTok: TToken;
begin
  if ALitStart < AEndExclusive then
  begin
    LLitTok := Default(TToken);

    LLitTok.Kind := tkLiteral;
    LLitTok.Lit := Copy(APattern, ALitStart, AEndExclusive - ALitStart);
    AddToken(LLitTok, ATokens, ACount);
  end;
end;

// AClassIdx is at '[' on entry; on success it is moved past the closing
// ']'.  Mirrors the interpreting engine's FindClassEnd + CharInClass* +
// MatchQuotedAltClass* parsing rules exactly - the two engines MUST stay
// in agreement (the benchmark app has a parity suite that checks this).
class function TWildCard.ParseClassToken(const APattern: string; var AClassIdx: Integer; var AToken: TToken;
  const ALen: Integer): Boolean;
var
  LPos, LContentStart, LContentEnd, LQStart: Integer;
  LAltCount: Integer;
  LAlt: string;
begin
  AToken := Default(TToken);

  LPos := AClassIdx + 1;

  if (LPos <= ALen) and (APattern[LPos] = '!') then
  begin
    AToken.Negate := True;
    Inc(LPos);
  end;

  if (LPos <= ALen) and (APattern[LPos] = '"') then
  begin
    // Quoted alternation form.
    AToken.Kind := tkAltGroup;
    AToken.MaxAltLen := 0;
    AToken.MinAltLen := MaxInt;
    LAltCount := 0;

    while True do
    begin
      if LPos > ALen then
        Exit(False);

      if APattern[LPos] = ']' then
        Break;

      if APattern[LPos] <> '"' then
        Exit(False);

      Inc(LPos);
      LQStart := LPos;

      while (LPos <= ALen) and (APattern[LPos] <> '"') do
        Inc(LPos);

      if LPos > ALen then
        Exit(False);

      LAlt := Copy(APattern, LQStart, LPos - LQStart);
      Inc(LPos);

      if LAltCount = Length(AToken.Alts) then
        SetLength(AToken.Alts, (LAltCount * 2) + 4);

      AToken.Alts[LAltCount] := LAlt;
      Inc(LAltCount);

      if Length(LAlt) > AToken.MaxAltLen then
        AToken.MaxAltLen := Length(LAlt);
      if Length(LAlt) < AToken.MinAltLen then
        AToken.MinAltLen := Length(LAlt);

      // After an alternative: '|' continues, ']' ends (checked at loop
      // top), anything else - including a bare '"' - is malformed.
      if LPos > ALen then
        Exit(False);

      if APattern[LPos] = '|' then
        Inc(LPos)
      else if APattern[LPos] <> ']' then
        Exit(False);
    end;

    SetLength(AToken.Alts, LAltCount);

    if LAltCount = 0 then
      Exit(False);

    AClassIdx := LPos + 1;
    Exit(True);
  end;

  // Legacy single-char class form.
  AToken.Kind := tkCharClass;
  LContentStart := LPos;
  LContentEnd := LPos;

  // First content char ']' is a literal member.
  if (LContentEnd <= ALen) and (APattern[LContentEnd] = ']') then
    Inc(LContentEnd);

  while (LContentEnd <= ALen) and (APattern[LContentEnd] <> ']') do
    Inc(LContentEnd);

  if LContentEnd > ALen then
    Exit(False);

  // Content spans [LContentStart .. LContentEnd - 1]; LContentEnd = ']'.
  // 'X-Y' is a range when '-' is followed by a real content character
  // (same rule as CharInClass*).
  LPos := LContentStart;

  while LPos < LContentEnd do
  begin
    if (LPos + 2 < LContentEnd) and (APattern[LPos + 1] = '-') then
    begin
      SetLength(AToken.Ranges, Length(AToken.Ranges) + 1);
      AToken.Ranges[High(AToken.Ranges)].Lo := APattern[LPos];
      AToken.Ranges[High(AToken.Ranges)].Hi := APattern[LPos + 2];

      Inc(LPos, 3);
    end
    else
    begin
      AToken.Singles := AToken.Singles + APattern[LPos];

      Inc(LPos);
    end;
  end;

  AClassIdx := LContentEnd + 1;
  Result := True;
end;

class function TWildCard.CompilePattern(const APattern: string): TCompiledPattern;
var
  LLen, LIdx, LLitStart: Integer;
  LTokens: TArray<TToken>;
  LCount: Integer;
  LTok: TToken;
  LMin: Integer;
begin
  Result.Valid := True;
  Result.Tokens := nil;

  LLen := Length(APattern);
  LTokens := nil;
  LCount := 0;
  LIdx := 1;
  LLitStart := 1;

  while LIdx <= LLen do
  begin
    case APattern[LIdx] of
      '*':
        begin
          FlushLiteralToken(APattern, LIdx, LLitStart, LTokens, LCount);

          while (LIdx <= LLen) and (APattern[LIdx] = '*') do
            Inc(LIdx);

          LTok := Default(TToken);
          LTok.Kind := tkStar;
          AddToken(LTok, LTokens, LCount);

          LLitStart := LIdx;
        end;
      '?':
        begin
          FlushLiteralToken(APattern, LIdx, LLitStart, LTokens, LCount);

          LTok := Default(TToken);
          LTok.Kind := tkAnyChar;
          AddToken(LTok, LTokens, LCount);

          Inc(LIdx);
          LLitStart := LIdx;
        end;
      '#':
        begin
          FlushLiteralToken(APattern, LIdx, LLitStart, LTokens, LCount);

          LTok := Default(TToken);
          LTok.Kind := tkDigit;
          AddToken(LTok, LTokens, LCount);

          Inc(LIdx);
          LLitStart := LIdx;
        end;
      '[':
        begin
          FlushLiteralToken(APattern, LIdx, LLitStart, LTokens, LCount);

          if not ParseClassToken(APattern, LIdx, LTok, LLen) then
          begin
            // Malformed class - the pattern can never match anything
            // (same behaviour as the interpreting engine).
            Result.Valid := False;
            Exit;
          end;

          AddToken(LTok, LTokens, LCount);
          LLitStart := LIdx;
        end;
    else
      Inc(LIdx);
    end;
  end;

  FlushLiteralToken(APattern, LLen + 1, LLitStart, LTokens, LCount);
  SetLength(LTokens, LCount);

  // Back-fill MinRemain: minimum input chars needed from token i to the
  // end of the pattern.  Used to prune '*' scans and to reject too-short
  // inputs before the engine even starts.
  LMin := 0;

  for LIdx := LCount - 1 downto 0 do
  begin
    case LTokens[LIdx].Kind of
      tkLiteral:
        Inc(LMin, Length(LTokens[LIdx].Lit));
      tkAnyChar, tkDigit, tkCharClass:
        Inc(LMin);
      tkStar:
        ; // consumes zero at minimum
      tkAltGroup:
        if LTokens[LIdx].Negate then
          Inc(LMin, LTokens[LIdx].MaxAltLen)
        else
          Inc(LMin, LTokens[LIdx].MinAltLen);
    end;

    LTokens[LIdx].MinRemain := LMin;
  end;

  Result.Tokens := LTokens;
end;

class function TWildCard.CharInCompiledClass(const AToken: TToken; const AChar: Char): Boolean;
var
  LIdx: Integer;
begin
  Result := False;

  for LIdx := 1 to Length(AToken.Singles) do
    if AChar = AToken.Singles[LIdx] then
    begin
      Result := True;
      Break;
    end;

  if not Result then
    for LIdx := 0 to High(AToken.Ranges) do
      if (AChar >= AToken.Ranges[LIdx].Lo) and (AChar <= AToken.Ranges[LIdx].Hi) then
      begin
        Result := True;
        Break;
      end;

  if AToken.Negate then
    Result := not Result;
end;

// Case-insensitive literal-run compare: pattern side (ALit) is already
// upper-cased at Create time; the input side gets the ordinal pre-check +
// FastToUpper treatment per char.  Bounds are the caller's responsibility.
class function TWildCard.LiteralMatchesAtCI(const AInput: string; const AInputIdx: Integer; const ALit: string): Boolean;
var
  LIdx: Integer;
begin
  for LIdx := 1 to Length(ALit) do
    if (AInput[AInputIdx + LIdx - 1] <> ALit[LIdx]) and (FastToUpper(AInput[AInputIdx + LIdx - 1]) <> ALit[LIdx]) then
      Exit(False);

  Result := True;
end;

class function TWildCard.MatchTokensCS(const ATokens: TArray<TToken>; const AInput: string; AInputIdx, ATokenIdx: Integer): Boolean;
var
  LInputLen: Integer;
  LTok, LNext: PToken;
  LLitLen, LIdx, LMaxStart: Integer;
  LAltIdx, LAltLen: Integer;
  LChar: Char;
{$IF Defined(USE_SSE2) and Defined(WIN32)}
  LRel: Integer;
{$ENDIF}
begin
  LInputLen := Length(AInput);

  while ATokenIdx <= High(ATokens) do
  begin
    LTok := @ATokens[ATokenIdx];

    case LTok.Kind of
      tkLiteral:
        begin
          LLitLen := Length(LTok.Lit);

          if AInputIdx + LLitLen - 1 > LInputLen then
            Exit(False);

          if not CompareMem(@AInput[AInputIdx], Pointer(LTok.Lit), LLitLen * SizeOf(Char)) then
            Exit(False);

          Inc(AInputIdx, LLitLen);
          Inc(ATokenIdx);
        end;
      tkAnyChar:
        begin
          if AInputIdx > LInputLen then
            Exit(False);

          Inc(AInputIdx);
          Inc(ATokenIdx);
        end;
      tkDigit:
        begin
          if (AInputIdx > LInputLen) or not IsAsciiDigit(AInput[AInputIdx]) then
            Exit(False);

          Inc(AInputIdx);
          Inc(ATokenIdx);
        end;
      tkCharClass:
        begin
          if AInputIdx > LInputLen then
            Exit(False);

          if not CharInCompiledClass(LTok^, AInput[AInputIdx]) then
            Exit(False);

          Inc(AInputIdx);
          Inc(ATokenIdx);
        end;
      tkAltGroup:
        begin
          if LTok.Negate then
          begin
            // None of the alternatives may be a prefix here; consume the
            // longest alternative's length on success.
            for LAltIdx := 0 to High(LTok.Alts) do
            begin
              LAltLen := Length(LTok.Alts[LAltIdx]);

              if (LAltLen = 0) or
                 ((AInputIdx + LAltLen - 1 <= LInputLen) and
                  CompareMem(@AInput[AInputIdx], Pointer(LTok.Alts[LAltIdx]), LAltLen * SizeOf(Char))) then
                Exit(False);
            end;

            if (LTok.MaxAltLen > 0) and (AInputIdx + LTok.MaxAltLen - 1 > LInputLen) then
              Exit(False);

            Inc(AInputIdx, LTok.MaxAltLen);
            Inc(ATokenIdx);
          end
          else
          begin
            // Alternatives differ in length, so each candidate needs its
            // own continuation attempt.
            for LAltIdx := 0 to High(LTok.Alts) do
            begin
              LAltLen := Length(LTok.Alts[LAltIdx]);

              if (LAltLen = 0) or
                ((AInputIdx + LAltLen - 1 <= LInputLen) and
                CompareMem(@AInput[AInputIdx], Pointer(LTok.Alts[LAltIdx]), LAltLen * SizeOf(Char))) then
                if MatchTokensCS(ATokens, AInput, AInputIdx + LAltLen, ATokenIdx + 1) then
                  Exit(True);
            end;

            Exit(False);
          end;
        end;
      tkStar:
        begin
          if ATokenIdx = High(ATokens) then
            Exit(True); // trailing '*' absorbs the rest

          LNext := @ATokens[ATokenIdx + 1];

          // Prune: positions past LMaxStart cannot fit the remainder.
          LMaxStart := LInputLen - LNext.MinRemain + 1;

          case LNext.Kind of
            tkLiteral:
              begin
                LLitLen := Length(LNext.Lit);

                // Tail anchor: '*literal' at the very end of the pattern.
                if ATokenIdx + 1 = High(ATokens) then
                begin
                  LIdx := LInputLen - LLitLen + 1;

                  if LIdx < AInputIdx then
                    Exit(False);

                  Exit(CompareMem(@AInput[LIdx], Pointer(LNext.Lit), LLitLen * SizeOf(Char)));
                end;

                // First-char skip: only recurse where the literal starts.
                LChar := LNext.Lit[1];

{$IF Defined(USE_SSE2) and Defined(WIN32)}
                while AInputIdx <= LMaxStart do
                begin
                  LRel := ScanCharIndex(PChar(Pointer(AInput)) + AInputIdx - 1, LMaxStart - AInputIdx + 1, LChar);
                  if LRel < 0 then
                    Break;

                  Inc(AInputIdx, LRel);

                  if MatchTokensCS(ATokens, AInput, AInputIdx, ATokenIdx + 1) then
                    Exit(True);

                  Inc(AInputIdx);
                end;
{$ELSE}
                while AInputIdx <= LMaxStart do
                begin
                  if AInput[AInputIdx] = LChar then
                    if MatchTokensCS(ATokens, AInput, AInputIdx, ATokenIdx + 1) then
                      Exit(True);

                  Inc(AInputIdx);
                end;
{$ENDIF}
              end;
            tkDigit:
              begin
                while AInputIdx <= LMaxStart do
                begin
                  if IsAsciiDigit(AInput[AInputIdx]) then
                    if MatchTokensCS(ATokens, AInput, AInputIdx, ATokenIdx + 1) then
                      Exit(True);

                  Inc(AInputIdx);
                end;
              end;
            tkCharClass:
              begin
                while AInputIdx <= LMaxStart do
                begin
                  if CharInCompiledClass(LNext^, AInput[AInputIdx]) then
                    if MatchTokensCS(ATokens, AInput, AInputIdx, ATokenIdx + 1) then
                      Exit(True);

                  Inc(AInputIdx);
                end;
              end;
          else
            // tkAnyChar / tkAltGroup: no cheap per-position filter, but
            // the MinRemain prune still bounds the scan.
            while AInputIdx <= LMaxStart do
            begin
              if MatchTokensCS(ATokens, AInput, AInputIdx, ATokenIdx + 1) then
                Exit(True);

              Inc(AInputIdx);
            end;
          end;

          Exit(False);
        end;
    end;
  end;

  Result := AInputIdx > LInputLen;
end;

class function TWildCard.MatchTokensCI(const ATokens: TArray<TToken>; const AInput: string; AInputIdx, ATokenIdx: Integer): Boolean;
var
  LInputLen: Integer;
  LTok, LNext: PToken;
  LLitLen, LIdx, LMaxStart: Integer;
  LAltIdx, LAltLen: Integer;
  LChar: Char;
{$IF Defined(USE_SSE2) and Defined(WIN32)}
  LRel: Integer;
  LCharPair: Cardinal;
{$ENDIF}
begin
  LInputLen := Length(AInput);

  while ATokenIdx <= High(ATokens) do
  begin
    LTok := @ATokens[ATokenIdx];

    case LTok.Kind of
      tkLiteral:
        begin
          LLitLen := Length(LTok.Lit);

          if AInputIdx + LLitLen - 1 > LInputLen then
            Exit(False);

          if not LiteralMatchesAtCI(AInput, AInputIdx, LTok.Lit) then
            Exit(False);

          Inc(AInputIdx, LLitLen);
          Inc(ATokenIdx);
        end;
      tkAnyChar:
        begin
          if AInputIdx > LInputLen then
            Exit(False);

          Inc(AInputIdx);
          Inc(ATokenIdx);
        end;
      tkDigit:
        begin
          if (AInputIdx > LInputLen) or not IsAsciiDigit(AInput[AInputIdx]) then
            Exit(False);

          Inc(AInputIdx);
          Inc(ATokenIdx);
        end;
      tkCharClass:
        begin
          if AInputIdx > LInputLen then
            Exit(False);

          if not CharInCompiledClass(LTok^, FastToUpper(AInput[AInputIdx])) then
            Exit(False);

          Inc(AInputIdx);
          Inc(ATokenIdx);
        end;
      tkAltGroup:
        begin
          if LTok.Negate then
          begin
            for LAltIdx := 0 to High(LTok.Alts) do
            begin
              LAltLen := Length(LTok.Alts[LAltIdx]);

              if (LAltLen = 0) or
                 ((AInputIdx + LAltLen - 1 <= LInputLen) and
                  LiteralMatchesAtCI(AInput, AInputIdx, LTok.Alts[LAltIdx])) then
                Exit(False);
            end;

            if (LTok.MaxAltLen > 0) and (AInputIdx + LTok.MaxAltLen - 1 > LInputLen) then
              Exit(False);

            Inc(AInputIdx, LTok.MaxAltLen);
            Inc(ATokenIdx);
          end
          else
          begin
            for LAltIdx := 0 to High(LTok.Alts) do
            begin
              LAltLen := Length(LTok.Alts[LAltIdx]);

              if (LAltLen = 0) or
                 ((AInputIdx + LAltLen - 1 <= LInputLen) and
                  LiteralMatchesAtCI(AInput, AInputIdx, LTok.Alts[LAltIdx])) then
                if MatchTokensCI(ATokens, AInput, AInputIdx + LAltLen, ATokenIdx + 1) then
                  Exit(True);
            end;

            Exit(False);
          end;
        end;
      tkStar:
        begin
          if ATokenIdx = High(ATokens) then
            Exit(True);

          LNext := @ATokens[ATokenIdx + 1];
          LMaxStart := LInputLen - LNext.MinRemain + 1;

          case LNext.Kind of
            tkLiteral:
              begin
                LLitLen := Length(LNext.Lit);

                if ATokenIdx + 1 = High(ATokens) then
                begin
                  LIdx := LInputLen - LLitLen + 1;

                  if LIdx < AInputIdx then
                    Exit(False);

                  Exit(LiteralMatchesAtCI(AInput, LIdx, LNext.Lit));
                end;

                LChar := LNext.Lit[1];

{$IF Defined(USE_SSE2) and Defined(WIN32)}
                if (LChar >= 'A') and (LChar <= 'Z') then
                  LCharPair := Cardinal(Ord(LChar)) or (Cardinal(Ord(LChar) + 32) shl 16)
                else
                  LCharPair := Cardinal(Ord(LChar)) or (Cardinal(Ord(LChar)) shl 16);

                while AInputIdx <= LMaxStart do
                begin
                  LRel := ScanCharIndexCI(PChar(Pointer(AInput)) + AInputIdx - 1, LMaxStart - AInputIdx + 1, LCharPair);
                  if LRel < 0 then
                    Break;

                  Inc(AInputIdx, LRel);

                  // Candidates include non-ASCII chars - re-verify before
                  // recursing (see ScanCharIndexCI).
                  if (AInput[AInputIdx] = LChar) or (FastToUpper(AInput[AInputIdx]) = LChar) then
                    if MatchTokensCI(ATokens, AInput, AInputIdx, ATokenIdx + 1) then
                      Exit(True);

                  Inc(AInputIdx);
                end;
{$ELSE}
                while AInputIdx <= LMaxStart do
                begin
                  if (AInput[AInputIdx] = LChar) or (FastToUpper(AInput[AInputIdx]) = LChar) then
                    if MatchTokensCI(ATokens, AInput, AInputIdx, ATokenIdx + 1) then
                      Exit(True);

                  Inc(AInputIdx);
                end;
{$ENDIF}
              end;
            tkDigit:
              begin
                while AInputIdx <= LMaxStart do
                begin
                  if IsAsciiDigit(AInput[AInputIdx]) then
                    if MatchTokensCI(ATokens, AInput, AInputIdx, ATokenIdx + 1) then
                      Exit(True);

                  Inc(AInputIdx);
                end;
              end;
            tkCharClass:
              begin
                while AInputIdx <= LMaxStart do
                begin
                  if CharInCompiledClass(LNext^, FastToUpper(AInput[AInputIdx])) then
                    if MatchTokensCI(ATokens, AInput, AInputIdx, ATokenIdx + 1) then
                      Exit(True);

                  Inc(AInputIdx);
                end;
              end;
          else
            while AInputIdx <= LMaxStart do
            begin
              if MatchTokensCI(ATokens, AInput, AInputIdx, ATokenIdx + 1) then
                Exit(True);

              Inc(AInputIdx);
            end;
          end;

          Exit(False);
        end;
    end;
  end;

  Result := AInputIdx > LInputLen;
end;

function TWildCard.MatchCompiled(const ACompiled: TCompiledPattern; const AInput: string): Boolean;
begin
  if not ACompiled.Valid then
    Exit(False);

  if Length(ACompiled.Tokens) = 0 then
    Exit(AInput = '');

  // Whole-pattern minimum-length quick reject.
  if Length(AInput) < ACompiled.Tokens[0].MinRemain then
    Exit(False);

  if FCaseSensitive then
    Result := MatchTokensCS(ACompiled.Tokens, AInput, 1, 0)
  else
    Result := MatchTokensCI(ACompiled.Tokens, AInput, 1, 0);
end;

{ TWildCard - instance API: Create overloads }

class function TWildCard.Create(const ACaseSensitive: Boolean): TWildCard;
begin
  Result.FCaseSensitive := ACaseSensitive;
  Result.FPatterns := nil;
  Result.FCompiled := nil;
end;

class function TWildCard.Create(const APattern: string; const ACaseSensitive: Boolean): TWildCard;
begin
  Result.FCaseSensitive := ACaseSensitive;
  SetLength(Result.FPatterns, 1);

  if ACaseSensitive then
    Result.FPatterns[0] := APattern
  else
    Result.FPatterns[0] := FastUpperString(APattern);

  SetLength(Result.FCompiled, 1);

  Result.FCompiled[0] := CompilePattern(Result.FPatterns[0]);
end;

class function TWildCard.Create(const APatterns: TArray<string>; const ACaseSensitive: Boolean): TWildCard;
var
  LIdx: Integer;
begin
  Result.FCaseSensitive := ACaseSensitive;
  SetLength(Result.FPatterns, Length(APatterns));

  if ACaseSensitive then
  begin
    for LIdx := 0 to High(APatterns) do
      Result.FPatterns[LIdx] := APatterns[LIdx];
  end
  else
  begin
    for LIdx := 0 to High(APatterns) do
      Result.FPatterns[LIdx] := FastUpperString(APatterns[LIdx]);
  end;

  SetLength(Result.FCompiled, Length(Result.FPatterns));

  for LIdx := 0 to High(Result.FPatterns) do
    Result.FCompiled[LIdx] := CompilePattern(Result.FPatterns[LIdx]);
end;

class function TWildCard.Create(const APatterns: TStrings; const ACaseSensitive: Boolean): TWildCard;
var
  LIdx: Integer;
begin
  Result.FCaseSensitive := ACaseSensitive;
  SetLength(Result.FPatterns, APatterns.Count);

  if ACaseSensitive then
  begin
    for LIdx := 0 to APatterns.Count - 1 do
      Result.FPatterns[LIdx] := APatterns[LIdx];
  end
  else
  begin
    for LIdx := 0 to APatterns.Count - 1 do
      Result.FPatterns[LIdx] := FastUpperString(APatterns[LIdx]);
  end;

  SetLength(Result.FCompiled, Length(Result.FPatterns));

  for LIdx := 0 to High(Result.FPatterns) do
    Result.FCompiled[LIdx] := CompilePattern(Result.FPatterns[LIdx]);
end;

{ TWildCard - instance API: Match overloads }

function TWildCard.MatchRegistered(const AInput: string): Boolean;
var
  LIdx: Integer;
begin
  // Registered patterns were compiled at Create - each Match call runs the
  // token engine directly with no per-call preparation or pattern
  // re-scanning.  Index loop on purpose: for-in over a string array copies
  // each element (refcount churn).
  for LIdx := 0 to High(FCompiled) do
    if MatchCompiled(FCompiled[LIdx], AInput) then
      Exit(True);

  Result := False;
end;

function TWildCard.Match(const AInput: string): Boolean;
begin
  Result := MatchRegistered(AInput);
end;

function TWildCard.Match(const AInput, APattern: string; const AAlsoMatchRegistered: Boolean): Boolean;
begin
  // Try the ad-hoc pattern first (must FastUpperString it because it was
  // not pre-prepared at Create time).
  if FCaseSensitive then
    Result := MatchRecursiveCS(AInput, APattern, 1, 1)
  else
    Result := MatchRecursiveCI(AInput, FastUpperString(APattern), 1, 1);

  if Result then
    Exit;

  if AAlsoMatchRegistered then
    Result := MatchRegistered(AInput);
end;

function TWildCard.Match(const AInput: string; const APatterns: TArray<string>; const AAlsoMatchRegistered: Boolean): Boolean;
var
  LPattern: string;
begin
  if FCaseSensitive then
  begin
    for LPattern in APatterns do
      if MatchRecursiveCS(AInput, LPattern, 1, 1) then
        Exit(True);
  end
  else
  begin
    for LPattern in APatterns do
      if MatchRecursiveCI(AInput, FastUpperString(LPattern), 1, 1) then
        Exit(True);
  end;

  if AAlsoMatchRegistered then
    Result := MatchRegistered(AInput)
  else
    Result := False;
end;

function TWildCard.Match(const AInput: string; const APatterns: TStrings; const AAlsoMatchRegistered: Boolean): Boolean;
var
  LIdx: Integer;
begin
  if FCaseSensitive then
  begin
    for LIdx := 0 to APatterns.Count - 1 do
      if MatchRecursiveCS(AInput, APatterns[LIdx], 1, 1) then
        Exit(True);
  end
  else
  begin
    for LIdx := 0 to APatterns.Count - 1 do
      if MatchRecursiveCI(AInput, FastUpperString(APatterns[LIdx]), 1, 1) then
        Exit(True);
  end;

  if AAlsoMatchRegistered then
    Result := MatchRegistered(AInput)
  else
    Result := False;
end;

{ TWildCardFilter }

class function TWildCardFilter.Create(const ACaseSensitive: Boolean): TWildCardFilter;
begin
  Result.FCaseSensitive := ACaseSensitive;
  Result.FInclude := TWildCard.Create(ACaseSensitive);
  Result.FExclude := TWildCard.Create(ACaseSensitive);
  Result.FHasIncludes := False;
end;

class function TWildCardFilter.Create(const AIncludePattern, AExcludePattern: string; const ACaseSensitive: Boolean): TWildCardFilter;
begin
  // Convenience single-pattern form.  An empty string means "no pattern
  // for that side" (an empty include pattern would otherwise register a
  // pattern that matches only the empty input - never the intent here).
  Result.FCaseSensitive := ACaseSensitive;

  if AIncludePattern <> '' then
    Result.FInclude := TWildCard.Create(AIncludePattern, ACaseSensitive)
  else
    Result.FInclude := TWildCard.Create(ACaseSensitive);

  if AExcludePattern <> '' then
    Result.FExclude := TWildCard.Create(AExcludePattern, ACaseSensitive)
  else
    Result.FExclude := TWildCard.Create(ACaseSensitive);

  Result.FHasIncludes := AIncludePattern <> '';
end;

class function TWildCardFilter.Create(const AIncludePatterns, AExcludePatterns: TArray<string>; const ACaseSensitive: Boolean): TWildCardFilter;
begin
  Result.FCaseSensitive := ACaseSensitive;
  Result.FInclude := TWildCard.Create(AIncludePatterns, ACaseSensitive);
  Result.FExclude := TWildCard.Create(AExcludePatterns, ACaseSensitive);
  Result.FHasIncludes := Length(AIncludePatterns) > 0;
end;

class function TWildCardFilter.Create(const AIncludePatterns, AExcludePatterns: TStrings; const ACaseSensitive: Boolean): TWildCardFilter;
begin
  Result.FCaseSensitive := ACaseSensitive;

  if Assigned(AIncludePatterns) then
    Result.FInclude := TWildCard.Create(AIncludePatterns, ACaseSensitive)
  else
    Result.FInclude := TWildCard.Create(ACaseSensitive);

  if Assigned(AExcludePatterns) then
    Result.FExclude := TWildCard.Create(AExcludePatterns, ACaseSensitive)
  else
    Result.FExclude := TWildCard.Create(ACaseSensitive);

  Result.FHasIncludes := Assigned(AIncludePatterns) and (AIncludePatterns.Count > 0);
end;

function TWildCardFilter.Accepts(const AInput: string): Boolean;
begin
  // Include stage: only restricts when there are include patterns.
  if FHasIncludes and not FInclude.Match(AInput) then
    Exit(False);

  // Exclude stage: any hit rejects.  Match on an empty registered set
  // returns False, so an empty exclude list excludes nothing.
  Result := not FExclude.Match(AInput);
end;

function TWildCardFilter.GetIncludePatterns: TArray<string>;
begin
  Result := FInclude.RegisteredPatterns;
end;

function TWildCardFilter.GetExcludePatterns: TArray<string>;
begin
  Result := FExclude.RegisteredPatterns;
end;

end.
