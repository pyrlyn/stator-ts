# T12. Closing report

Done: peak memory on VS Code at `-j 16` fell from 15.7 GB to 9.8 GB of RSS, or from 16.85 GB to 10.51 GB of peak footprint, and the run did not get slower. It now sits level with tsc 7 and still above tsc-rs.

Commits: `f5dd6f7`, `117620e`, `13e40af`, `b025523`, `9da5a7d`, `2edb63f`, `5883c02`, `b0dea21`, `940063b`, `42fdeab`, and the commit that adds this report.

## Before and after

VS Code at `-j 16`, ReleaseFast, peak memory footprint from `/usr/bin/time -l`. Every row kept 291 of 291 with none extra. `task.md` mixes two measures: its 16.8 GB is footprint and its 13.4 GB is RSS. Footprint with one worker at the start was 14.43 GB.

| Step | Commit | Peak | Wall |
| --- | --- | --- | --- |
| Start | `ea06ee0` | 16.85 GB | 2.48-2.63 s |
| Checker lists sized from the first item | part of `f5dd6f7` | 15.72 GB | 2.54-2.85 s |
| Property tables sized, literals keep their table, calls sized | `f5dd6f7` | 13.75 GB | 2.54-2.74 s |
| Parser node lists grow from one item | `117620e` | 13.37 GB | 2.13-2.46 s |
| `Node` 112 to 80 bytes | `13e40af` | 12.75 GB | 2.08-2.41 s |
| Module resolution reads into a scratch arena | `b025523` | 12.39 GB | 2.17-2.40 s |
| `Mapper` 64 to 32 bytes, candidate lists sized | `9da5a7d` | 11.95 GB | 2.41-2.56 s |
| `Type` 104 to 64 bytes | `2edb63f` | 11.68 GB | 2.38-2.59 s |
| `Obj` 216 to 104 bytes | `5883c02` | 11.14 GB | 2.46-3.00 s |
| `Prop` 96 to 80 bytes | `b0dea21` | 10.96 GB | 2.23-2.60 s |
| Scratch lists on the stack, inference mappers on demand | `940063b` | 10.67 GB | 2.44-2.71 s |
| Flow labels sized | `42fdeab` | 10.51 GB | 2.24-2.70 s |

The largest single find was the growth policy of `std.ArrayList`: the first append of a pointer list reserves 17 items, and an arena never gives them back.

At each job count, final build:

| `-j` | Wall | Footprint | Match of 291 |
| --- | --- | --- | --- |
| 1 | 18.38 s | 8.72 GB | 291, none extra |
| 2 | 9.95 s | 8.96 GB | 291, none extra |
| 4 | 5.33 s | 9.28 GB | 291, none extra |
| 8 | 3.38 s | 9.83 GB | 291, none extra |
| 16 | 2.43 s | 10.51 GB | 291, none extra |

Five interleaved rounds of the final build, RSS: stator-ts 2.32-2.71 s, 9.78 GB; tsc-rs `--fast` 3.00-3.49 s, 7.77 GB; tsc-rs 5.24-5.58 s, 6.93 GB; tsc 7 10.40-11.08 s, 9.84-10.49 GB.

## How it was checked

- `zig build test` after each commit.
- `tests/differential.sh`: 876 of 879 with none extra, the same three missed (`private-name-in-type-query`, `constraint-position-narrowing`, `mapped-known-keys-generic-index`), exact column on 872 of 876.
- `tests/ts7/run.mjs`: 8136 known passing, 0 lost, 0 gained.
- VS Code and the fixtures on a ReleaseSafe build: 291 of 291, the same fixture result, no assertion or safety panic. That covers the new `appendAssumeCapacity` sites and the `arrayMapper` length assertion.
- `basesOf` now returns nothing for an object without class data. VS Code, the fixtures and the TS7 suite ran with a panic on any such object carrying a symbol other than a mapped type, and it never fired. Mapped types do arrive there, and their declarations have no heritage.

## What stopped it

The rest is real data. Allocation in one checker fell from 6687 MB to 5317 MB, no site is above 6%, and the tail is flat. About 3.2 GB of the peak is AST and symbols, shared by every checker.

Tried and dropped: moving `calls`, `ctors` and `indexes` out of `Members` gave 80 MB for two setters and about 30 edited sites, because many objects do have signatures. The same trade was skipped for `Symbol` and `Sig`, at an estimated 100 MB each.

The cuts left each need something new rather than a local change: members of instantiated generics built on demand, or checker memory freed file by file. Both are in `ideas.md`. T10's sharing stays open and can win little: sixteen checkers cost about 1.1 GB of RSS more than one.
