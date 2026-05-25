unit Delphi.WildCardMatcher;

// Windows / DOS style wildcard matcher with a few common extensions.
//
//   *       matches zero or more characters (line-agnostic)
//   ?       matches exactly one character
//   #       matches exactly one decimal digit (0-9)
//   |       matches one or more line endings (CRLF / LF / CR, mix-tolerant)
//   [abc]   matches any one of the characters in the set
//   [!abc]  matches any one character NOT in the set
//   [a-z]   matches any one character in the range (low..high, ascending)
//
// Sets may combine literals and ranges, e.g. '[a-zA-Z0-9_]'.
// A literal ']' inside a set must be the first content character: '[]abc]'
// matches ']', 'a', 'b' or 'c'.  '[!]abc]' negates the same set.
// A '-' that is the first or last content character is treated as a literal,
// e.g. '[-x]' matches '-' or 'x'; '[a-]' matches 'a' or '-'.
//
// '|' is the inverse of '*' for line structure: '*' matches anything
// (including newlines), '|' REQUIRES at least one newline.  A CRLF pair is
// one line ending, lone CR and lone LF each count as one, so mixed-EOL
// files are handled without surprises.  Use '||' the same as '|' (collapses
// like '**' collapses to '*').
//
// '|' is the chosen operator because the characters Windows forbids in file
// names are '< > : " / \ | ? *', and '*' / '?' are already taken.  This
// keeps wildcard patterns safe to use as literal file masks.
//
// Matching is case-insensitive by default (Windows convention); pass
// ACaseSensitive = True for ordinal comparison.  The case-sensitive and
// case-insensitive engines are separate code paths - no per-character
// branch on the flag - so case-sensitive matching is noticeably faster.
//
// The multi-pattern overloads return True on the first pattern that matches
// (short-circuit) and do not report which one - keep the call site simple.

interface

uses
  System.Classes;

type
  TWildCard = record
  strict private
    // Case-independent helpers
    class function IsAsciiDigit(const AChar: Char): Boolean; static; inline;
    class function IsEolChar(const AChar: Char): Boolean; static; inline;
    class function ConsumeOneEol(const AInput: string; const AIndex: Integer): Integer; static; inline;
    class function FindClassEnd(const APattern: string; const AStart: Integer): Integer; static;

    // Case-sensitive path (direct ordinal compare, no ToUpper calls)
    class function CharInClassCS(const APattern: string; const AStart, AEnd: Integer; const AChar: Char): Boolean; static;
    class function MatchRecursiveCS(const AInput, APattern: string; AInputIdx, APatternIdx: Integer): Boolean; static;

    // Case-insensitive path (ToUpper compare)
    class function CharInClassCI(const APattern: string; const AStart, AEnd: Integer; const AChar: Char): Boolean; static;
    class function MatchRecursiveCI(const AInput, APattern: string; AInputIdx, APatternIdx: Integer): Boolean; static;
  public
    class function Match(const AInput, APattern: string; const ACaseSensitive: Boolean = False): Boolean; overload; static;
    class function Match(const AInput: string; const APatterns: TArray<string>; const ACaseSensitive: Boolean = False): Boolean; overload; static;
    class function Match(const AInput: string; const APatterns: TStrings; const ACaseSensitive: Boolean = False): Boolean; overload; static;
  end;

implementation

uses
  System.Character;

{ TWildCard - shared helpers }

class function TWildCard.IsAsciiDigit(const AChar: Char): Boolean;
begin
  Result := (AChar >= '0') and (AChar <= '9');
end;

class function TWildCard.IsEolChar(const AChar: Char): Boolean;
begin
  Result := (AChar = #13) or (AChar = #10);
end;

class function TWildCard.ConsumeOneEol(const AInput: string; const AIndex: Integer): Integer;
begin
  // CRLF is consumed as a single unit; lone CR or lone LF count as one each.
  // Caller must ensure the position holds a CR or LF.
  if (AInput[AIndex] = #13) and (AIndex < Length(AInput)) and (AInput[AIndex + 1] = #10) then
    Result := AIndex + 2
  else
    Result := AIndex + 1;
end;

class function TWildCard.FindClassEnd(const APattern: string; const AStart: Integer): Integer;
var
  LIndex: Integer;
begin
  // AStart points at '['. Returns index of ']' that closes the class, or 0
  // if the class is unterminated.  First content char ']' is treated as a
  // literal (so '[]abc]' is a valid class containing ']abc').
  LIndex := AStart + 1;

  if (LIndex <= Length(APattern)) and (APattern[LIndex] = '!') then
    Inc(LIndex);

  if (LIndex <= Length(APattern)) and (APattern[LIndex] = ']') then
    Inc(LIndex);

  while LIndex <= Length(APattern) do
  begin
    if APattern[LIndex] = ']' then
      Exit(LIndex);

    Inc(LIndex);
  end;

  Result := 0;
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

class function TWildCard.MatchRecursiveCS(const AInput, APattern: string; AInputIdx, APatternIdx: Integer): Boolean;
var
  LClassEnd: Integer;
begin
  while APatternIdx <= Length(APattern) do
  begin
    case APattern[APatternIdx] of
      '*':
        begin
          while (APatternIdx <= Length(APattern)) and (APattern[APatternIdx] = '*') do
            Inc(APatternIdx);

          if APatternIdx > Length(APattern) then
            Exit(True);

          while AInputIdx <= Length(AInput) + 1 do
          begin
            if MatchRecursiveCS(AInput, APattern, AInputIdx, APatternIdx) then
              Exit(True);

            Inc(AInputIdx);
          end;

          Exit(False);
        end;
      '?':
        begin
          if AInputIdx > Length(AInput) then
            Exit(False);

          Inc(AInputIdx);
          Inc(APatternIdx);
        end;
      '#':
        begin
          if AInputIdx > Length(AInput) then
            Exit(False);

          if not IsAsciiDigit(AInput[AInputIdx]) then
            Exit(False);

          Inc(AInputIdx);
          Inc(APatternIdx);
        end;
      '|':
        begin
          while (APatternIdx <= Length(APattern)) and (APattern[APatternIdx] = '|') do
            Inc(APatternIdx);

          if (AInputIdx > Length(AInput)) or not IsEolChar(AInput[AInputIdx]) then
            Exit(False);

          AInputIdx := ConsumeOneEol(AInput, AInputIdx);

          while True do
          begin
            if MatchRecursiveCS(AInput, APattern, AInputIdx, APatternIdx) then
              Exit(True);

            if (AInputIdx > Length(AInput)) or not IsEolChar(AInput[AInputIdx]) then
              Exit(False);

            AInputIdx := ConsumeOneEol(AInput, AInputIdx);
          end;
        end;
      '[':
        begin
          if AInputIdx > Length(AInput) then
            Exit(False);

          LClassEnd := FindClassEnd(APattern, APatternIdx);
          if LClassEnd = 0 then
            Exit(False);

          if not CharInClassCS(APattern, APatternIdx, LClassEnd, AInput[AInputIdx]) then
            Exit(False);

          Inc(AInputIdx);
          APatternIdx := LClassEnd + 1;
        end;
    else
      begin
        if AInputIdx > Length(AInput) then
          Exit(False);

        if AInput[AInputIdx] <> APattern[APatternIdx] then
          Exit(False);

        Inc(AInputIdx);
        Inc(APatternIdx);
      end;
    end;
  end;

  Result := AInputIdx > Length(AInput);
end;

{ TWildCard - case-insensitive path }

class function TWildCard.CharInClassCI(const APattern: string; const AStart, AEnd: Integer;
  const AChar: Char): Boolean;
var
  LIndex: Integer;
  LNegate: Boolean;
  LCharUpper: Char;
begin
  // Upper-case the input character once outside the class-walk loop.
  LCharUpper := AChar.ToUpper;

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
      if (LCharUpper >= APattern[LIndex].ToUpper)
         and (LCharUpper <= APattern[LIndex + 2].ToUpper) then
        Result := True;

      Inc(LIndex, 3);
    end
    else
    begin
      if LCharUpper = APattern[LIndex].ToUpper then
        Result := True;

      Inc(LIndex);
    end;
  end;

  if LNegate then
    Result := not Result;
end;

class function TWildCard.MatchRecursiveCI(const AInput, APattern: string; AInputIdx, APatternIdx: Integer): Boolean;
var
  LClassEnd: Integer;
begin
  while APatternIdx <= Length(APattern) do
  begin
    case APattern[APatternIdx] of
      '*':
        begin
          while (APatternIdx <= Length(APattern)) and (APattern[APatternIdx] = '*') do
            Inc(APatternIdx);

          if APatternIdx > Length(APattern) then
            Exit(True);

          while AInputIdx <= Length(AInput) + 1 do
          begin
            if MatchRecursiveCI(AInput, APattern, AInputIdx, APatternIdx) then
              Exit(True);

            Inc(AInputIdx);
          end;

          Exit(False);
        end;
      '?':
        begin
          if AInputIdx > Length(AInput) then
            Exit(False);

          Inc(AInputIdx);
          Inc(APatternIdx);
        end;
      '#':
        begin
          if AInputIdx > Length(AInput) then
            Exit(False);

          if not IsAsciiDigit(AInput[AInputIdx]) then
            Exit(False);

          Inc(AInputIdx);
          Inc(APatternIdx);
        end;
      '|':
        begin
          while (APatternIdx <= Length(APattern)) and (APattern[APatternIdx] = '|') do
            Inc(APatternIdx);

          if (AInputIdx > Length(AInput)) or not IsEolChar(AInput[AInputIdx]) then
            Exit(False);

          AInputIdx := ConsumeOneEol(AInput, AInputIdx);

          while True do
          begin
            if MatchRecursiveCI(AInput, APattern, AInputIdx, APatternIdx) then
              Exit(True);

            if (AInputIdx > Length(AInput)) or not IsEolChar(AInput[AInputIdx]) then
              Exit(False);

            AInputIdx := ConsumeOneEol(AInput, AInputIdx);
          end;
        end;
      '[':
        begin
          if AInputIdx > Length(AInput) then
            Exit(False);

          LClassEnd := FindClassEnd(APattern, APatternIdx);
          if LClassEnd = 0 then
            Exit(False);

          if not CharInClassCI(APattern, APatternIdx, LClassEnd, AInput[AInputIdx]) then
            Exit(False);

          Inc(AInputIdx);
          APatternIdx := LClassEnd + 1;
        end;
    else
      begin
        if AInputIdx > Length(AInput) then
          Exit(False);

        if AInput[AInputIdx].ToUpper <> APattern[APatternIdx].ToUpper then
          Exit(False);

        Inc(AInputIdx);
        Inc(APatternIdx);
      end;
    end;
  end;

  Result := AInputIdx > Length(AInput);
end;

{ TWildCard - public Match overloads }

class function TWildCard.Match(const AInput, APattern: string;
  const ACaseSensitive: Boolean): Boolean;
begin
  if ACaseSensitive then
    Result := MatchRecursiveCS(AInput, APattern, 1, 1)
  else
    Result := MatchRecursiveCI(AInput, APattern, 1, 1);
end;

class function TWildCard.Match(const AInput: string; const APatterns: TArray<string>;
  const ACaseSensitive: Boolean): Boolean;
var
  LPattern: string;
begin
  // Hoist the case-sensitivity dispatch outside the per-pattern loop so the
  // inner loop calls the specialised engine directly.
  if ACaseSensitive then
  begin
    for LPattern in APatterns do
      if MatchRecursiveCS(AInput, LPattern, 1, 1) then
        Exit(True);
  end
  else
  begin
    for LPattern in APatterns do
      if MatchRecursiveCI(AInput, LPattern, 1, 1) then
        Exit(True);
  end;

  Result := False;
end;

class function TWildCard.Match(const AInput: string; const APatterns: TStrings;
  const ACaseSensitive: Boolean): Boolean;
var
  LIndex: Integer;
begin
  if ACaseSensitive then
  begin
    for LIndex := 0 to APatterns.Count - 1 do
      if MatchRecursiveCS(AInput, APatterns[LIndex], 1, 1) then
        Exit(True);
  end
  else
  begin
    for LIndex := 0 to APatterns.Count - 1 do
      if MatchRecursiveCI(AInput, APatterns[LIndex], 1, 1) then
        Exit(True);
  end;

  Result := False;
end;

end.
