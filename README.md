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

### Single pattern

```pascal
if TWildCard.Match(AFileName, '*.pas') then
  // ...

// Case-sensitive
if TWildCard.Match('Unit1.PAS', '*.pas', True) then
  // ... will NOT match because of the trailing-case difference
```

### Multiple patterns (TArray<string>)

Short-circuits on the first match.

```pascal
const
  PASCAL_EXTS: TArray<string> = ['*.pas', '*.dpr', '*.dpk', '*.inc'];
begin
  if TWildCard.Match(AFileName, PASCAL_EXTS) then
    AddToProjectFileList(AFileName);
end;
```

### Multiple patterns (TStrings)

Same semantics; handy when the patterns come from a `TStringList`,
`Memo.Lines`, an `.ini` file, etc.

```pascal
var
  LMasks: TStringList;
begin
  LMasks := TStringList.Create;
  try
    LMasks.LoadFromFile('ignore-masks.txt');

    for var LFile in TDirectory.GetFiles(ARoot) do
      if not TWildCard.Match(LFile, LMasks) then
        ProcessFile(LFile);
  finally
    LMasks.Free;
  end;
end;
```

### Structural matching with `|`

Because `|` requires a real line break, you can sketch the shape of a
multi-line text without caring about what is on each line:

```pascal
TWildCard.Match(LSourceCode, 'unit *;|interface|*|implementation|*|end.');
```

This matches any Pascal unit whose top-level structure has `interface`
and `implementation` sections on their own lines, regardless of CRLF / LF
mixing or how many blank lines separate the sections.

## API

```pascal
type
  TWildCard = record
  public
    class function Match(const AInput, APattern: string;
      const ACaseSensitive: Boolean = False): Boolean; overload; static;

    class function Match(const AInput: string; const APatterns: TArray<string>;
      const ACaseSensitive: Boolean = False): Boolean; overload; static;

    class function Match(const AInput: string; const APatterns: TStrings;
      const ACaseSensitive: Boolean = False): Boolean; overload; static;
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
