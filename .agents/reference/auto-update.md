<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Auto-Update

Polls GitHub every 10 min; runs `aidevops update` on new version. Safe during active sessions.

**CLI**: `aidevops auto-update [enable|disable|status|check|logs]`

**Scheduler**: Three backends depending on platform:
- **macOS**: launchd LaunchAgent (`~/Library/LaunchAgents/com.aidevops.aidevops-auto-update.plist`). Auto-migrates existing cron entries on first `enable`.
- **Linux (preferred)**: systemd user timer (`~/.config/systemd/user/aidevops-auto-update.timer` + `.service`). Selected by `_detect_linux_scheduler` when `systemctl --user` is available — this is the default on most modern Linux desktops and servers.
- **Linux (fallback)**: cron (crontab entry with `# aidevops-auto-update` marker). Used when `systemctl --user` is unavailable (e.g., containers without systemd).

## Linux systemd: logout persistence (linger)

On Linux hosts using the systemd backend, the auto-update timer runs inside the **user** systemd manager. By default, the user manager stops when your last session ends — taking the timer with it.

**When you need linger**: always on servers and headless hosts where you SSH in, run `aidevops auto-update enable`, then log out. Without linger, the timer fires only while you're logged in.

**When you don't need it**: laptops or desktops where a graphical session is always running.

**Enable once** (requires sudo):

```bash
sudo loginctl enable-linger $USER
```

Check current state: `aidevops auto-update status` shows a `Linger: yes|no` row on systemd hosts.

**Disable**: `aidevops auto-update disable`, `"auto_update": false` in settings.json, or `AIDEVOPS_AUTO_UPDATE=false`. Priority: env > settings.json > default (`true`). **Logs**: `~/.aidevops/logs/auto-update.log`

**Skill refresh**: 24h-gated via `skill-update-helper.sh --auto-update --quiet`. Disable: `AIDEVOPS_SKILL_AUTO_UPDATE=false`. Frequency: `AIDEVOPS_SKILL_FRESHNESS_HOURS=<hours>` (default: 24).

**Upstream watch**: `upstream-watch-helper.sh check` — monitors external repos for new releases. Config: `.agents/configs/upstream-watch.json`. State: `~/.aidevops/cache/upstream-watch-state.json`. Commands: `status`, `check`, `ack <slug>`.

GitHub entries monitor releases and commits by default. Use `upstream-watch-helper.sh add <owner/repo> --releases-only` or set `watch_mode` to `releases` for fast-moving inspiration repos where commit-level alerts would create noise. Optional committed `baseline_release` and `baseline_commit` values seed missing local state at the last reviewed version; later acknowledgements remain in the local state file.

**Update behavior**: Shared agents overwritten on update. Only `custom/` and `draft/` preserved.

## Related

- `reference/services.md` — Services & Integrations index
