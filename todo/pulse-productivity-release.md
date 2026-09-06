# Productivity release source manifest

The user explicitly authorizes full-loop release of the productivity recovery.
Include every otherwise-unreleased PR merged since v3.32.317, with immutable
source identities. This metadata-only aggregate changes no implementation policy.

| PR | Verified merge commit |
| --- | --- |
| 31344 | 5c702adebe65f7e8516dd806af74561b1b5575e0 |
| 31345 | be2fdf9596987a19d5d02361df3a3e6dbb5f586f |
| 31347 | ef84049ee8e36bbce2a6142da98262b2870f0080 |
| 31349 | bbe4e343ecdf3828d9bb757c6fbba4c29291a38c |
| 31350 | f78f46c309f0efd69b44167eea05768cfc6c3cc4 |
| 31352 | 0585d06eb49bc458c13a398d33fedb4f055df8e7 |

Verification: observed merged PR identities and exact required-check success;
productivity changes additionally passed focused transport, cooldown, dispatch,
scope-retry and report tests plus independent review and Qlty. The signed tag,
publication channels, postflight and exact-tag deployment remain owned by the
canonical release helper. The release is not complete merely because this
aggregate merges or a tag exists.
