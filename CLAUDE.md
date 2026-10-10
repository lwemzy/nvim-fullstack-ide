# Instructions for Claude Code in this repo

## CHANGELOG.md must stay current

Every commit that changes behavior (a fix, a feature, a config/plugin
change — not a pure comment/doc/test-only change with no behavior shift)
must add an entry to `CHANGELOG.md` in the *same commit*, under today's
date (newest date at the top of the file; newest entry within a date at
the top of that date's section).

Entry format, matching the existing file:

```
## YYYY-MM-DD

- **<one-line summary, same as the commit subject>** (`<short-hash>`)
  - <why it mattered / what broke / what changed, one bullet per point>
```

The short hash is only known after committing, so the usual order is:
write the change, write the CHANGELOG.md entry with a placeholder or the
subject only, commit, then if the hash needs backfilling amend only as
part of that same uncommitted work (never amend an already-pushed commit
just to fix the changelog).

Do not create a changelog entry for test-only changes, comment fixes, or
other no-behavior-change edits. Do not skip this for "small" fixes — the
2026-10-09 entry for the harper_ls settings one-liner is the precedent.
