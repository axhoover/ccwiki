# Review fixtures

Read by `DiffGuardTests` and `GitNameStatusTests` through `#filePath`
(plans/corrections.md §12.1). The test target excludes `Fixtures/`, so none of
this is bundled.

| File | What it is |
|---|---|
| `pseudorandom-function.md` | `content/Primitives/pseudorandom-function.md` from axhoover/cryptology.city at `ab81f02`, byte for byte. Its “Participates in” region (lines 153–176) carries the checksum `865206d47c53`, which `lint.mjs` accepts. Its `variants` name the anchors `#invertible-prfs` and `#weak-prfs`. |
| `name-status.z` | `git diff --cached -M --name-status -z HEAD` from git 2.43, in a scratch repository with a modified page, a deleted page, an added page whose name has a space, a page that gained its final newline, a rename to a name with `&`, a space and a non-ASCII letter (`R100`), a modified binary and an added binary. |
| `numstat.z` | `git diff --cached --numstat -z HEAD` for the same change. No `-M`: git detects the rename anyway (`diff.renames`) and writes it as `0\t0\t\0<old>\0<new>\0`. |
| `staged.patch` | `git diff --cached --binary HEAD` for the same change. Its SHA-256 is `d2f71b32c9b6f7ea8ca95e37347920bb23f3739dbd98ed4b790c62fbd5011c20`. |

The texts of the scratch repository's files are spelled out in
`GitNameStatusTests`, so `ReviewSnapshot.assemble` can be checked against the
same change end to end.
