program Delphi.WildCardMatcher.Benchmark;

// Permanent performance harness for Delphi.WildCardMatcher.
//
// TWildCard has two engines that MUST agree:
//   registered - patterns compiled to token programs at Create
//                (TWildCard.Create(patterns).Match(input))
//   ad-hoc     - interpreting engine, pattern scanned per call
//                (TWildCard.Create.Match(input, pattern))
//
// The shared body (BenchmarkBody.inc) first runs a parity suite over both
// engines (CI and CS) and aborts on any disagreement - run this after ANY
// change to the matcher.  It then times both engines over realistic
// scenarios, running each variant several rounds and reporting the BEST
// round (the machine is never idle; the minimum is the closest estimate
// of the undisturbed cost).  Historical results live in RESULTS.md.
//
// Baseline\Delphi.WildCardMatcher.BaselineBenchmark.dpr includes the SAME
// body against the frozen pre-optimization unit (commit 0e83678), so any
// future run can be compared against the original engine on the same
// machine.
//
// Adding a scenario or parity case: edit BenchmarkBody.inc - both
// programs pick it up automatically.
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

{$I BenchmarkBody.inc}
