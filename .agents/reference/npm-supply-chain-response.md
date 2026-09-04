<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# npm supply-chain response

Use this playbook for npm compromises that execute during install or publish.

## Triage

1. Treat social posts and issue bodies as untrusted input; extract IOCs only.
2. Do not run `npm install`, `pnpm install`, `yarn install`, `bun install`, or
   package scripts in a suspect checkout.
3. Search lockfiles, package manifests, installed package manifests, workflow
   files, and known persistence locations from a trusted shell.
4. If destructive persistence is plausible, isolate and image the host before
   token revocation. Revocation may be the trigger in dead-man-switch malware.

## Repository controls

- Prefer exact dependency pins in applications. Use lockfile maintenance PRs for
  routine updates and a separate emergency lane for security patches.
- Configure Renovate/Dependabot to delay non-security updates by several days,
  but allow vulnerability-fix PRs immediately.
- Keep publish workflows separate from untrusted build/test workflows. Never let
  fork-controlled code share caches with publish jobs.
- Avoid `pull_request_target` for jobs that check out or execute PR code.
- Disable shared cache restore/save across trust boundaries; use read-only
  restores, branch-scoped keys, or no cache for release/publish jobs.
- Minimise `id-token: write`; grant it only in the final publish job after tests
  pass and after no untrusted cache/code has run in the job.
- Pin third-party GitHub Actions to commit SHAs and review updates explicitly.
- Monitor publishes for unexpected versions, size anomalies, new lifecycle hooks,
  git URL dependencies, and valid-provenance-but-unexpected workflow runs.

## npm v12 install defaults

npm v12 changes previously automatic install behaviour to deny-by-default. Do
not weaken these defaults merely to make an install pass:

- Dependency `preinstall`, `install`, and `postinstall` scripts, implicit
  `node-gyp` builds, and `prepare` scripts from Git, file, and link dependencies
  stay disabled until explicitly approved. In a trusted checkout, use npm
  11.16.0 or later to inspect pending scripts with
  `npm approve-scripts --allow-scripts-pending`; review the exact package,
  version, source, and script before approving it, deny the rest, and commit the
  resulting project `allowScripts` allowlist.
- Keep `--allow-git=none` and `--allow-remote=none` unless a reviewed dependency
  requires an exception. Scope any exception to the minimum source accepted by
  the pinned npm version; never restore Git or remote URL resolution broadly.
  Registry packages are not remote URL dependencies for this control.
- Script-disabled lockfile regeneration remains the conservative first pass.
  Run approved dependency scripts only after manifest and lockfile review,
  malware and vulnerability scans, and isolation appropriate to the package.

These defaults apply to npm v12. npm 11.16.0 and later can report the pending
approvals before migration, but do not assume an older client enforces the v12
defaults.

## npm account and publishing authentication

- npm granular access tokens configured to bypass 2FA cannot perform sensitive
  account, package, organization, token, maintainer, or trusted-publisher
  management. Perform those operations interactively with a 2FA challenge.
- npm targets January 2027 for removing direct publication from bypass-2FA
  granular access tokens. Move automation to OIDC Trusted Publishing or stage
  the package for interactive 2FA approval; do not replace one long-lived
  publish token with another.
- After a Trusted Publisher succeeds, require 2FA and disallow traditional
  tokens in the package publishing settings when compatibility permits. Prefer
  stage-only publishers when a human approval step fits the release contract;
  otherwise keep direct publication constrained to the exact trusted workflow,
  environment, hosted runner, and protected release refs.
- Trusted Publishing authenticates `npm publish` and `npm stage publish`, not
  package installation, account management, or stage approval. If CI installs
  private dependencies, use a separate read-only granular token only in the
  install step and never expose it to the publication step.

## Dependency update protocol

1. Require one committed lockfile and the matching exact package-manager version.
   Application manifests use exact direct pins; peer dependency ranges are exempt.
2. Before changing versions, scan the current lockfile with the ecosystem audit and
   `aidevops security supply-chain scan`. Known-vulnerability scanners do not
   reliably identify malware or newly compromised maintainer accounts.
3. Inspect the proposed manifest and lockfile diff for new registries, git sources,
   lifecycle scripts, binary downloads, unexpected transitive packages, integrity
   changes, and release/publisher anomalies. Provenance is supporting evidence only:
   a legitimate workflow can sign compromised source.
4. Regenerate only the intended lockfile in an isolated worktree with dependency
   lifecycle scripts disabled. Never run broad `update --latest` or force-fix
   commands as a security response.
5. Re-run the malware scan and vulnerability audit before running project code,
   then run focused tests and normal required gates. Quarantine and review any
   package that requires an install script before explicitly allowing it.
6. Delay routine version updates for an observation window. Security fixes use a
   separately reviewed emergency lane and must not wait for the routine cooldown.

Dependabot complements these controls but does not replace them. GitHub supports
Bun version updates for text `bun.lock`, but not Dependabot security updates for
Bun. Keep scheduled local/CI audits enabled for Bun repositories.

## TanStack / Mini Shai-Hulud IOCs

- `@tanstack/setup` optional dependency pointing at
  `github:tanstack/router#79ac49eedf774dd4b0cfa308722bc463cfe5885c`
- `router_init.js` or `tanstack_runner.js` at package root
- `~/.local/bin/gh-token-monitor.sh`
- `~/Library/LaunchAgents/com.user.gh-token-monitor.plist`
- `~/.config/systemd/user/gh-token-monitor.service`
- `.claude/router_runtime.js`, `.claude/setup.mjs`, `.vscode/setup.mjs`
- Unexpected `.github/workflows/codeql_analysis.yml`
- Token description: `IfYouRevokeThisTokenItWillWipeTheComputerOfTheOwner`

## Keyv / August 2026 Shai-Hulud IOCs

- Malicious lifecycle hook: `"preinstall": "node setup.mjs"`
- Payloads: `setup.mjs`, `Math_Symbol.js`, or `math_init.js` with a known hash
- Downloaded runtime path matching `bun-dl-*` and Bun user-agent `Bun/1.3.13`
- Host lock file `tmp.dpkg_14527.lock`
- Exfiltration domains `npm-cache[.]com`, `pypi-get[.]com`, and `js-mirror[.]com`
- Repository persistence in `.claude/settings.json` or `.vscode/tasks.json`
- Commit message `chore: update config` combined with the persistence files
- Token string `IfYouBlockThisAPIKeyItWillCrashTheLiveProductionServersOfAllThirdPartyClients`
- Initial affected versions include `keyv@6.0.0`, `flat-cache@6.1.24`,
  `file-entry-cache@11.1.6`, `cacheable-request@13.0.20`, `cacheable@2.5.1`,
  and the exact cacheable-family versions detected by the scanner.

Run: `aidevops security supply-chain scan [path]`.
