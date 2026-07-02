program Delphi.WildCardMatcher.BaselineBenchmark;

// BASELINE benchmark: runs the exact same scenarios as the main benchmark
// (shared BenchmarkBody.inc) against the FROZEN pre-optimization matcher
// from commit 0e83678 ('New Syntax, EOL stuff met its End Of Life') that
// lives next to this file.  That commit has the full current syntax
// (quoted alternation included) but none of the engine optimizations, so
// it is the reference point for all speedup claims in RESULTS.md.
//
// Do NOT edit Baseline\Delphi.WildCardMatcher.pas - it is a historical
// snapshot.
//
// Build & run:
//   "%ProgramFiles(x86)%\Embarcadero\Studio\37.0\bin\rsvars.bat"
//   dcc32 -B -$O+ -$R- -$Q- -I".." -E"Win32" -N"Win32" Delphi.WildCardMatcher.BaselineBenchmark.dpr
//   Win32\Delphi.WildCardMatcher.BaselineBenchmark.exe

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Diagnostics,
  Delphi.WildCardMatcher in 'Delphi.WildCardMatcher.pas';

{$I ..\BenchmarkBody.inc}
