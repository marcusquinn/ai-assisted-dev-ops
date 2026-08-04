<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Tabby profiles

Use `.agents/scripts/tabby-profile-sync.py` to generate aidevops project profiles
from `repos.json`. When `~/.buzz` exists, setup/update also generates a `Buzz`
profile rooted there so OpenCode opens the Buzz-scoped session namespace. The
profile is omitted when Buzz has not created that workspace, and an existing
profile with the same working directory remains user-owned and unchanged.

OpenCode profiles must not launch with `zsh -i -c opencode`. That shape runs an
interactive zsh startup while executing a command string, which can make
Powerlevel10k/gitstatus initialize before job control is available and emit
errors such as `setopt: can't change option: monitor` or `gitstatus failed to
initialize` before the TUI starts.

Do not use `TABBY_AUTORUN=opencode` for generated profiles. It depends on a
`.zshrc` startup hook and can fail silently, leaving users in a plain shell.

Do not put `/bin/zsh -l -c 'opencode; exec zsh'` in Tabby's `command` field.
Tabby expects `command` to be the executable path and shell flags to be separate
`args`; using the whole command string can make profile launches fail.

Tabby's command-line editor parses unquoted shell operators (`&&`, `;`, `>`,
and similar) into object-valued arguments. Its PTY launcher accepts only string
arguments, so such a saved profile can leave the Tabby renderer unresponsive.
For a custom command containing operators, paste the complete quoted invocation
`/bin/zsh -l -c '<command>'` into the combined command-line field. Do not paste
only the inner command. `tabby-helper.sh status` reports profiles containing
non-string arguments and exits nonzero; repair them before launch.

The safe generated shape is:

```yaml
command: /bin/zsh
args:
  - '-l'
  - '-c'
  - 'opencode; exec zsh'
env: {}
```

For manual one-off profiles that should run OpenCode and then leave a shell open,
use the same non-interactive login command instead of mixing `-i` and `-c`:

```yaml
command: /bin/zsh
args:
  - '-l'
  - '-c'
  - 'opencode; exec zsh'
```
