# Delphi.WildCardMatcher

Simple Windows / DOS style wildcard matcher for Delphi, with a couple of
useful extensions (`#` for digits, `|` for line breaks).

Pure Pascal, single unit, no dependencies beyond the RTL.

## Wildcard syntax

| Token    | Matches                                                  | Example pattern | Matches            | Does not match    |
| -------- | -------------------------------------------------------- | --------------- | ------------------ | ----------------- |
| `*`      | Zero or more characters (including newlines)             | `wh*`           | `what`, `why`      | `awhile`, `watch` |
| `?`      | Exactly one character                                    | `b?ll`          | `ball`, `bell`     | `bll`, `baal`     |
| `#`      | Exactly one decimal digit (0-9)                          | `1#3`           | `103`, `113`       | `1a3`, `13`       |
| `[abc]`  | Any one character in the set                             | `b[ae]ll`       | `ball`, `bell`     | `bill`            |
| `[!abc]` | Any one character NOT in the set                         | `b[!ae]ll`      | `bill`, `bull`     | `ball`, `bell`    |
| `[a-z]`  | Any one character in the range (low..high, ascending)    | `b[a-c]d`       | `bad`, `bbd`       | `bdd`, `b0d`      |
| `\|`     | One or more line endings (CRLF / LF / CR, mix-tolerant)  | `file\|name`    | `file<CRLF>name`   | `filename`        |

Sets may combine literals and ranges, e.g. `[a-zA-Z0-9_]`.
A literal `]` inside a set must be the first content character:
`[]abc]` matches `]`, `a`, `b` or `c`.
A `-` that is the first or last content character is treated as a literal,
e.g. `[-x]` matches `-` or `x`; `[a-]` matches `a` or `-`.

`*` is line-agnostic; `|` REQUIRES at least one newline.
A CRLF pair is one line ending, lone CR and lone LF each count as one, so
mixed-EOL inputs are handled without surprises.
`**` collapses to `*` and `||` collapses to `|`.

Matching is **case-insensitive by default** (Windows convention).
Pass `ACaseSensitive = True` for ordinal comparison.

## Usage

```pascal
uses
  Delphi.WildCardMatcher;
```

### One-off match

`TWildCard.Create` (no patterns) gives you an empty matcher you can use
for ad-hoc one-shot calls. Case-sensitivity is set at `Create` time.

```pascal
if TWildCard.Create.Match(AFileName, '*.pas') then
  // ...

// Case-sensitive
if TWildCard.Create(True).Match('Unit1.PAS', '*.pas') then
  // ... will NOT match because of the trailing-case difference
```

### Pre-registered patterns (recommended for repeated matching)

When you match many inputs against the same fixed pattern set, register
the patterns at `Create` so the per-call upper-casing happens once. Then
`Match(input)` walks the registered set short-circuiting on the first hit.

```pascal
var
  LMask: TWildCard;
begin
  LMask := TWildCard.Create(['*.pas', '*.dpr', '*.dpk', '*.inc']);
  for var LFile in TDirectory.GetFiles(ARoot) do
    if LMask.Match(LFile) then
      AddToProjectFileList(LFile);
end;
```

The constructor accepts a single pattern, a `TArray<string>`, or a
`TStrings` (handy for patterns loaded from a `TStringList` /
`Memo.Lines` / `.ini` file):

```pascal
var
  LMasks: TStringList;
  LIgnore: TWildCard;
begin
  LMasks := TStringList.Create;
  try
    LMasks.LoadFromFile('ignore-masks.txt');
    LIgnore := TWildCard.Create(LMasks);

    for var LFile in TDirectory.GetFiles(ARoot) do
      if not LIgnore.Match(LFile) then
        ProcessFile(LFile);
  finally
    LMasks.Free;
  end;
end;
```

### Ad-hoc pattern on a registered instance

You can pass an extra one-off pattern to an existing instance. By
default only that pattern is tried; pass `True` as the third argument
to also try the registered set.

```pascal
LMask.Match(LFile, '*.dproj');           // only the ad-hoc pattern
LMask.Match(LFile, '*.dproj', True);     // ad-hoc + registered set
```

### Structural matching with `|`

Because `|` requires a real line break, you can sketch the shape of a
multi-line text without caring about what is on each line:

```pascal
TWildCard.Create.Match(LSourceCode, 'unit *;|interface|*|implementation|*|end.');
```

This matches any Pascal unit whose top-level structure has `interface`
and `implementation` sections on their own lines, regardless of CRLF / LF
mixing or how many blank lines separate the sections.

## API

```pascal
type
  TWildCard = record
  public
    // Constructors - ACaseSensitive is locked in for the lifetime of the
    // instance and defaults to case-insensitive (Windows convention).
    class function Create(const ACaseSensitive: Boolean = False): TWildCard; overload; static;
    class function Create(const APattern: string;
      const ACaseSensitive: Boolean = False): TWildCard; overload; static;
    class function Create(const APatterns: TArray<string>;
      const ACaseSensitive: Boolean = False): TWildCard; overload; static;
    class function Create(const APatterns: TStrings;
      const ACaseSensitive: Boolean = False): TWildCard; overload; static;

    // Match against the registered set only
    function Match(const AInput: string): Boolean; overload;

    // Match against an ad-hoc pattern; AAlsoMatchRegistered=True also
    // tries the registered set after the ad-hoc one fails.
    function Match(const AInput, APattern: string;
      const AAlsoMatchRegistered: Boolean = False): Boolean; overload;
    function Match(const AInput: string; const APatterns: TArray<string>;
      const AAlsoMatchRegistered: Boolean = False): Boolean; overload;
    function Match(const AInput: string; const APatterns: TStrings;
      const AAlsoMatchRegistered: Boolean = False): Boolean; overload;

    property CaseSensitive: Boolean read FCaseSensitive;
    property RegisteredPatterns: TArray<string> read FPatterns;
  end;
```

The multi-pattern overloads return `True` on the first pattern that matches
and `False` on an empty pattern list. They do not report which pattern
matched - keep the call site simple.

## Requirements

Modern Delphi (records with methods, `class function ... static`, generics).
Tested on Delphi 12.x. No third-party dependencies.

## Tests

DUnitX-based test suite under `Unittests\`. Open
`Delphi.WildCardMatcher.Tests.dproj` or run from the command line:

```
msbuild Unittests\Delphi.WildCardMatcher.Tests.dproj /t:Build /p:Config=Debug /p:Platform=Win32
Unittests\Win32\Debug\Delphi.WildCardMatcher.Tests.exe
```

## License

See [LICENSE](LICENSE).
