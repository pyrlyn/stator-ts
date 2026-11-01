# T4. Closing report

Done: on the VS Code corpus `check` reports the same 291 errors as tsc 7 by file, line and code, with no false positives and none missed. Each bug fixed along the way has a fixture in `tests/fixtures/`.

Commit: none, the project has no git repository of its own.

Checked: the numbers and suites in `plan/T11/done.md`, which ran on the same tree.

Still open, none of it seen on the corpus:

- Diagnostics not implemented: TS2612, TS1029, TS2507 and TS4112, TS2695, TS2440, TS18060, TS2320.
- Features not implemented: plain JS diagnostics and `checkJs`, evolving arrays, TS2564 on computed names.
- `const a` in one `switch` case read in another: tsc reports TS2454, stator-ts assumes it initialized, to save the walk.
- Message text differs from tsc in places, mostly printing of aliases, index parameter names, method members and union order. Compatibility counts file, line and code.
- The TS7 suite passes 59.2%; `plan/README.md` says what the rest is.
