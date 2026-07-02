# Benchmark results history

Harness: `Delphi.WildCardMatcher.Benchmark.dpr` - see its header comment
for how to build, run and extend it.  All runs Win32, dcc32 37.0 with
`-$O+ -$R- -$Q-`.  A parity suite (registered/compiled engine vs
ad-hoc/interpreting engine, CI and CS) must pass before anything is timed.

## 2026-07-02 (b): #11 integrated - compiled engine ships in TWildCard

Registered patterns are now compiled to token programs at `Create`;
ad-hoc `Match(input, pattern)` keeps the interpreting engine.

| Scenario | registered CI | ad-hoc CI | registered CS | ad-hoc CS |
| --- | ---: | ---: | ---: | ---: |
| S1 single mask `*.pas` | **8.7** | 38.7 | **6.8** | 24.9 |
| S2 8-mask ignore set | **49.8** | 216.9 | **46.8** | 98.5 |
| S3 worst-case backtracking | **1322** | 2090 | **597** | 850 |
| S4 quoted-alt mask | **165** | 942 | **111** | 797 |

(ns per Match call over the whole pattern set; ad-hoc CI pays a
FastUpperString per pattern per call on top of interpretation - that is
by design, ad-hoc is the convenience path.)

Registered vs the pre-integration registered engine (2026-07-02 (a)
"current CI" column): S1 23.5 -> 8.7 (2.7x), S2 98.5 -> 49.8 (2.0x),
S3 2000 -> 1322 (1.5x), S4 830 -> 165 (5.0x).

## 2026-07-02 (a): prototype evaluation of candidates #3 and #11

Decision run - measured against the then-shipping interpreting engine
(after the first optimization round: star fast paths, Char.ToUpper,
equality pre-checks etc.).

| Scenario | current | #3 | #11 +prep | #11 perchar |
| --- | ---: | ---: | ---: | ---: |
| S1 single mask `*.pas` | 23.5 | 50.1 | 38.7 | **7.3** |
| S2 8-mask ignore set | 98.5 | 113.3 | 75.2 | **53.1** |
| S3 worst-case backtracking (CI) | 2000 | 1147 | **872** | 1284 |
| S3 worst-case backtracking (CS) | 820 | - | **570** | - |
| S4 quoted-alt mask | 830 | 918 | **194** | 225 |

Verdicts (implemented in run (b)):

- **#3 (upper-case input per call) standalone: rejected.**  The per-call
  string allocation made it slower than the shipping engine in every
  realistic scenario; its theoretical win had already been captured by
  the equality pre-check and literal-tail fast path.
- **#11 with a per-char CI engine: integrated.**  Wins come from literal
  runs compared as blocks (CompareMem in CS), precompiled
  class/alternation descriptors (no re-parsing per backtrack position),
  MinRemain pruning of `*` scans, and a whole-pattern minimum-length
  quick reject.
- Ad-hoc one-shots keep the interpreting engine: per-call compilation
  allocations would likely eat the gains.  Benchmark that separately if
  it ever matters.
