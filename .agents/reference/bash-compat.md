<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Shell Portability: bash version + command coreutils

## GH#18950 (t2087) — macOS bash upgrade automation

**Since v3.8.25:** the framework automatically installs and maintains modern
bash (4+) on macOS via Homebrew, and self-heals at runtime by re-execing
scripts under modern bash when `/bin/bash` 3.2 is detected. This eliminates
the entire class of bugs from GH#18770, GH#18784, GH#18786, GH#18804, and
GH#18830 (bash 3.2 set-e propagation + parser quirks).

**Quick install** (run once, or let `setup.sh` prompt you):

```bash
brew install bash
```

**Verify:**

```bash
bash-upgrade-helper.sh status
# Platform:        macos
# Current bash:    5.3.9 (major=5)
# Modern bash:     /opt/homebrew/bin/bash (5.3.9(1)-release)
# Status:          OK
```

**How the four-part fix works (v3.8.25 + v3.8.28 updates):**

1. `bash-upgrade-helper.sh` — self-contained helper with `check`, `status`, `path`, `ensure`, `install`, `upgrade`, and `update-check` subcommands. Detects modern bash at `/opt/homebrew/bin/bash`, `/usr/local/bin/bash`, or `$(brew --prefix)/bin/bash`. **Canonical entry point is `ensure`** (since v3.8.28): it combines install-if-missing + upgrade-if-outdated + no-op-if-current, rate-limits `brew update` to once per 24h, and runs silently on upgrades (no prompt on every update cycle).
2. `setup.sh` — on macOS, calls `bash-upgrade-helper.sh ensure` after platform detection. Interactive mode prompts on first install (inherited from `_bu_cmd_install`), runs silently on subsequent upgrades. Non-interactive mode runs with `--yes --quiet` by default.
3. `aidevops-update-check.sh` — calls `bash-upgrade-helper.sh ensure --yes --quiet` in the periodic update cycle. **Actually runs `brew upgrade bash` on drift** (v3.8.28 change — previously advisory-only). Rate-limited internally via `~/.aidevops/state/brew-update-last-fetch` so multiple ensure calls in the same day share the fresh Homebrew index.
4. `shared-constants.sh` — runtime re-exec guard at the top of the file (after the include guard, before any readonly definitions). When sourced under bash 3.2 AND a modern bash is available, the guard `exec`s the calling script under the modern bash. Transparent to callers; 339 scripts get the self-heal for free. Chicken-and-egg-safe: `setup.sh` and `bash-upgrade-helper.sh` do NOT source `shared-constants.sh`, so the upgrade path itself is unaffected.

**Why actually upgrade, not just emit an advisory?** The framework's `aidevops update` already auto-pulls and auto-deploys new versions of aidevops every ~10 minutes — trusting it to `brew upgrade bash` (one binary, minor bumps only) is strictly less risky. Replacing a binary on disk does NOT kill running processes; existing bash processes continue on their in-memory copy. Only new invocations pick up the new version, and the re-exec guard makes that transparent.

**Opt-out**:
- Set `AIDEVOPS_AUTO_UPGRADE_BASH=0` in your shell profile to disable `ensure` (no auto install, no auto upgrade). You can still run `brew install bash` / `brew upgrade bash` manually at any time.
- Set `AIDEVOPS_BASH_REEXECED=1` to disable the runtime re-exec guard (scripts will run on whatever bash invoked them — e.g. `/bin/bash` 3.2 on macOS).

**Rollback:** `brew uninstall bash`. The runtime guard falls through gracefully when no modern bash is found, and scripts continue running on 3.2 (subject to the known bug class).

Regression test: `.agents/scripts/tests/test-bash-reexec-guard.sh` — 15 assertions (as of v3.8.28) covering detection, status output, guard positioning, loop prevention, the live re-exec fire path, `ensure` idempotence, and `AIDEVOPS_AUTO_UPGRADE_BASH=0` opt-out.

---

## The two compatibility axes

Two independent compatibility axes, both required:

1. **Bash version** — macOS ships bash 3.2.57; Linux ships bash 4.0+. Scripts must run on the LOWEST version (3.2). **Since v3.8.25**, modern bash is automatically installed on macOS via Homebrew, making this a soft requirement for NEW scripts — but existing scripts must still run under 3.2 as a fallback.
2. **Command coreutils** — macOS ships BSD coreutils (no `getent`, `stat --format`, `readlink -f`, `date -d`, `timeout`); has `dscl`, `sw_vers`, `launchctl`, `pbcopy`. Linux ships GNU coreutils with the inverse. Scripts must run on BOTH.

Regression pattern: a fix for one axis breaks the other. Recent production failures:

- **t2074 (GH#18784)** — #18686 added `getent passwd` to `aidevops.sh` to fix Linux-sudo home resolution, omitted the `command -v getent` guard that `approval-helper.sh:33` had. Broke `sudo aidevops approve` on macOS with `getent: command not found` for a full release cycle.
- **GH#18770** — #18712 refactored `pulse-wrapper.sh` to fix one bash 3.2 issue but forgot `set -e` exit propagation from a `local var=$(f)` capture. Killed the pulse on Linux silently (launchd kept relaunching).
- **t1983 (GH#18423)** — GNU-awk-specific dynamic-regex construct silently broke `add_gh_ref_to_todo` on macOS BSD awk for weeks.
- **#17944** — `stat` argument order was Linux-first across 6 scripts; macOS BSD `stat` ignored them.

**Test both platforms before merging.** ShellCheck catches neither axis — manual review and regression tests required.

CI also runs `.agents/scripts/platform-fix-regression-evidence.sh`: PRs that
claim Linux/macOS or coreutils portability fixes must update a targeted test or
include a substantive `## Regression Evidence` rationale. Documentation-only
changes are exempt; see `todo/plans/shell-portability-hardening.md` for context.

## Bash 3.2 Compatibility (macOS default shell)

macOS ships bash 3.2.57. All shell scripts MUST work on this version.
Bash 4.0+ features silently crash or produce wrong results — no error message.
Production failures: pulse dispatch, worktree cleanup, dataset helpers, routine scheduler.

## Forbidden features (bash 4.0+)

- `declare -A` / `local -A` — use parallel indexed arrays or grep-based lookup
- `mapfile` / `readarray` — use `while IFS= read -r line; do arr+=("$line"); done < <(cmd)`
- `${var,,}` / `${var^^}` (case conversion) — use `tr '[:upper:]' '[:lower:]'`
- `${var:offset:length}` negative offsets — use `${var: -N}` (space before minus)
- `|&` (pipe stderr) — use `2>&1 |`; `&>>` (append both) — use `>> file 2>&1`
- `declare -n` / `local -n` (namerefs) — use eval or indirect expansion `${!var}`
- `[[ $var =~ regex ]]` with stored regex — behaviour differs on 3.2, test explicitly

## Subshell and command substitution traps

- **Heredoc inside `$()`** — Bash 3.2 parser cannot handle heredocs inside command substitution. It fails with `unexpected EOF while looking for matching ')'` and silently corrupts all function definitions below the error point in the file. This caused a multi-hour pulse outage (GH#19252, April 2026). Use a quoted string assignment instead:

  ```bash
  # WRONG — breaks bash 3.2 parser
  msg=$(cat <<EOF
  Hello ${name}
  EOF
  )

  # RIGHT — works on all bash versions
  msg="Hello ${name}"
  ```

  CI gate: the `Bash 3.2 Compatibility` job greps for `$(cat <<` and the macOS `cross-platform-shellcheck` job runs `/bin/bash -n` (native 3.2 parser check) on all scripts.

- `$()` captures ALL stdout — never mix `tee` or command output with exit code capture. Write exit codes to a temp file: `printf '%s' "$?" > "$exit_code_file"`
- `local -a arr=()` inside `$()` — `local` in a subshell not inside a function is undefined in 3.2
- `PIPESTATUS` — available in 3.2 but only for the immediately preceding pipeline. Capture immediately: `cmd1 | cmd2; local ps=("${PIPESTATUS[@]}")`

## Heredoc apostrophe trap (bash 3.2)

A literal ASCII apostrophe (U+0027) inside an unquoted heredoc body (`<<EOF` / `<<TAG`) makes bash 3.2's single-quote tracker scan the body and fail with `unexpected EOF while looking for matching '` at the closing tag — even though the heredoc is well-formed. Fixed in bash 4.0 with lazy heredoc parsing. Distinct from GH#19252 above (fails looking for `)`); the failures share a parser ancestry but the trigger and error message differ. Canonical failure: `runtime-audit-rules/counter-trend-delta.sh` literal `supervisor's structural blind spot` broke `ShellCheck (macos-latest)` on main until t3082 (PR #21852) landed a 1-character fix. macOS `/bin/bash` is bash 3.2 forever (Apple license policy), so this trap will keep recurring on every contributor who writes `it's`, `won't`, or `supervisor's` inside a heredoc.

```bash
# WRONG — bash 3.2 fails: "unexpected EOF while looking for matching '"
cat <<EOF
it's a supervisor's blind spot
EOF
```

Three fixes, in order of preference:

- **(a) Quote the heredoc tag** — `<<'EOF'` (or `<<\EOF`). bash treats the body as a literal string and skips quote tracking entirely. **Side effect: loses `${var}` expansion** — use only when the body has no variables to interpolate.
- **(b) RECOMMENDED — U+2019** (right single quotation mark, `’`). Minimum diff, typographically correct, parser-safe on bash 3.2 and 4.x. Visually identical to U+0027 in most fonts; readers won't notice. Preserves `${var}` expansion. This is the fix t3082 / PR #21852 applied.
- **(c) Reword to avoid the apostrophe** — `it is`, `cannot`, `supervisor blind spot`. Zero parser interaction, no expansion tradeoff. Best when natural-language flow allows it.

CI gate: the existing `ShellCheck (macos-latest)` job (the `cross-platform-shellcheck` runner) runs `/bin/bash -n` against bash 3.2 — the canonical detector. Local check: `/bin/bash -n script.sh` on any macOS.

## Array passing across process boundaries

Arrays flatten to strings across subshell, `$()`, or pipe boundaries. Pass via `${arr[@]+"${arr[@]}"}` (positional args, safe under `set -u`) or temp file (one element per line, read back with `while IFS= read -r`).

## Escape sequence quoting (recurring production bug)

Bash double quotes do NOT interpret `\t` `\n` `\r` — literal two-character sequences. A single `"\t"` in a plist makes it unparseable and silently kills launchd jobs.

| Wrong | Correct | Notes |
|-------|---------|-------|
| `"\t"` | `$'\t'` | ANSI-C quoting for actual tab |
| `"\n"` | `$'\n'` | ANSI-C quoting for actual newline |
| `echo -e "\t"` | `printf '\t'` | `echo -e` is non-portable |
| `"${var}\t"` | `$'\t'"${var}"` | Concatenate ANSI-C quote + double-quote |

Inside heredocs (`<<EOF`), tabs are literal — `\t` is NOT interpreted. `printf '%s\t%s' "$a" "$b"` is the safest portable form.

## zsh IFS + `$()` trap (MCP Bash tool)

The MCP Bash tool runs zsh on macOS. In zsh, `path` is a SPECIAL TIED ARRAY linked to `PATH`.
`while IFS=$'\t' read -r size path` assigns `path=test.md` → sets `PATH=test.md` → ALL external commands fail. Variable name collision, not an IFS leak. Framework scripts with `#!/bin/bash` shebangs are safe; risk is inline agent-generated code only.

```bash
# WRONG — PATH=test.md, sed not found
echo -e "100\ttest.md" | while IFS=$'\t' read -r size path; do
  base=$(echo "$path" | sed 's|\.md$||')
done

# SAFE — rename variable; use parameter expansion instead of subshell
while IFS=$'\t' read -r size file_path; do
  base="${file_path%.md}"
done
```

zsh tied arrays — NEVER use as loop variables:
`path` (PATH), `manpath` (MANPATH), `cdpath` (CDPATH), `fpath` (FPATH), `mailpath` (MAILPATH), `module_path` (MODULE_PATH)

## Safe patterns

- Test with `/bin/bash` (not `/opt/homebrew/bin/bash`) to catch 4.0+ usage
- ShellCheck does NOT catch: bash version incompatibilities, `"\t"` vs `$'\t'`, zsh tied-array collisions — manual review required

---

## Cross-platform command portability (GNU ↔ BSD ↔ macOS)

Even with a compatible bash version, external commands diverge silently between Linux (GNU coreutils) and macOS (BSD coreutils). The runtime error is usually `command not found` or subtly wrong output — never a lint warning.

**Rule:** any command that is NOT in the intersection of GNU + BSD coreutils MUST be either (a) guarded by `command -v <cmd> &>/dev/null`, (b) branched on `[[ "$(uname)" == "Darwin" ]]`, or (c) wrapped in a canonical portable helper. Never call such commands unconditionally.

### Linux-only commands (crash on macOS without guard)

| Command | macOS alternative | Canonical portable pattern |
|---------|-------------------|----------------------------|
| `getent passwd $user` | `dscl . -read /Users/$user NFSHomeDirectory` | `setup-modules/shell-env.sh:33-38` (dscl-first, getent-fallback, $HOME-fallback) |
| `readlink -f <path>` | `perl -MCwd -e 'print Cwd::realpath($ARGV[0])' "$path"` or loop | Prefer `cd "$(dirname "$f")" && pwd -P` when practical |
| `stat --format='%Y' <f>` | `stat -f '%m' <f>` | Probe order must be **Linux-first** (GNU `stat --format` fails fast on BSD, allowing the fallback branch). See #17944. |
| `date -d '1 hour ago'` | `date -v-1H` | Python one-liner is the most portable: `python3 -c 'import datetime; print((datetime.datetime.now()-datetime.timedelta(hours=1)).isoformat())'` |
| `timeout <secs> <cmd>` | coreutils `gtimeout` if installed, else `perl -e 'alarm shift; exec @ARGV' <secs> <cmd>` | `aidevops.sh:_timeout_cmd()` |
| `sed -i '...'` (GNU) | `sed -i '' '...'` (BSD requires empty suffix) | `aidevops.sh:sed_inplace()` — `if Darwin; sed -i ''; else sed -i; fi` |
| `sed -r '...'` (extended regex) | `sed -E '...'` | `sed -E` works on both — always use `-E`, never `-r`. |
| `grep -P '...'` (PCRE) | N/A on BSD grep | Use `grep -E` with POSIX ERE, or pipe to `perl -ne '...'`. |
| `awk` dynamic regex `match($0, var)` | BSD awk rejects non-literal regex | Use `gsub()` with literal patterns, or switch to `perl`. Caught production bug t1983. |
| `awk` 3-arg `match(str, regex, capture_array)` | BSD awk has no capture-array form (gawk-only) | Use 2-arg `match(str, regex)`, then read `RSTART`/`RLENGTH` and slice with `substr()`. Caught during t2834 / PR #20883. |
| `awk -v key="$multi_line_value"` | BSD awk rejects embedded newlines in `-v` values | Stage the multi-line content to a temp file and slurp via `BEGIN { while ((getline line < f) > 0) arr[n++] = line; close(f) }`. Caught during t2834 / PR #20883. |
| `xargs -r` | BSD xargs has no `-r`; empty input is a no-op by default | Pre-check input with `[[ -s input ]]` before calling xargs, or use `find ... -exec {} +` which is portable. |
| `find -printf` | BSD find has no `-printf` | Use `find ... -exec <fmt-cmd> {} +` or pipe through `stat`. |
| `mktemp --suffix=.X` | BSD mktemp uses `-t prefix` differently | `mktemp -t aidevops.XXXXXX` works on both; never use `--suffix`. |
| `sha256sum <f>` | `shasum -a 256 <f>` | `shasum -a 256` is POSIX-compliant and available on both. |
| `base64 -w 0` | BSD `base64` has no `-w`; output is already one line | `base64 \| tr -d '\n'` portable. |
| `readelf`, `ldd`, `strace`, `lsof` flags | Different or missing | Not typically used in aidevops scripts; document if needed. |

### macOS-only commands (crash on Linux without guard)

| Command | Linux alternative | When used |
|---------|-------------------|-----------|
| `dscl . -read /Users/$u NFSHomeDirectory` | `getent passwd $u \| cut -d: -f6` | User home/shell lookup |
| `sw_vers -productVersion` | `lsb_release -rs` or `/etc/os-release` | OS version detection |
| `launchctl` | `systemctl` | Scheduler/service management |
| `pbcopy` / `pbpaste` | `xclip -selection clipboard` or `wl-copy` | Clipboard I/O |
| `sysctl -n hw.ncpu` | `nproc` or `sysctl -n kernel.ncpu` | CPU count (portable: `getconf _NPROCESSORS_ONLN`) |
| `defaults read/write` | N/A | macOS plist — always guard with `[[ "$(uname)" == "Darwin" ]]` |
| `security find-generic-password` | `secret-tool` or gopass | Keychain access |
| `codesign`, `xcrun`, `hdiutil` | N/A | macOS-only toolchain |

### Canonical portable wrappers (already in-tree)

Prefer these over inlining a conditional each time:

| Wrapper | Location | Purpose |
|---------|----------|---------|
| `sed_inplace` | `aidevops.sh:39` | In-place sed edit, BSD/GNU |
| `_timeout_cmd` | `aidevops.sh:42-55` | Timeout command with perl fallback |
| `_resolve_real_home()` | `.agents/scripts/approval-helper.sh:32-39` | SUDO_USER home resolution, dscl/getent/`$HOME` |
| `detect_default_shell()` | `setup-modules/shell-env.sh:28-45` | Login shell, dscl/getent/$SHELL |

When adding a new portable wrapper, document it in this table and ShellCheck-clean it.

### Pre-merge checklist for scripts that touch external commands

Before merging any shell script PR that touches coreutils, answer these:

1. Does the script call any command in the Linux-only or macOS-only tables above? If yes, is it guarded?
2. Does the CI matrix exercise both macOS + Linux for this script? (`bash-32-scanner` job in `.github/workflows/` + a manual macOS run.)
3. Is there a regression test that runs under the MISSING platform's conditions? (e.g., `test-aidevops-sh-portability.sh` strips `getent` off PATH to simulate macOS.)
4. Has the change been reviewed for `set -e` exit-code propagation through `local var=$(f)` captures? (GH#18770 cautionary tale.)

Failing any of these is a P0 regression risk — the bug will only surface on the unreviewed platform, often days after merge when the pulse or approval flow breaks silently.
