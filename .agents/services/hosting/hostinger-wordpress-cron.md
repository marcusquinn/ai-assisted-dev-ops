<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Hostinger WordPress Multisite Cron and Automatic-Update Readiness

Use this procedure during a Hostinger WordPress multisite migration, setup, or health
check. It is an operational guide, not a request to alter a live scheduler. Obtain
scoped approval before any production mutation and keep credentials, account IDs,
paths, provider output, and receipts private.

## Establish coverage before changing anything

The main site runs network-wide shared-file updates, but every active child site has
its own WordPress cron queue for scheduled content, queues, and plugin jobs. A plain
parent `wp-cron.php` job does not service every child. Repeating the same PHP command
in several cron rows without changing site context still targets the parent.

1. Establish the hosting-account and network boundaries, then inventory sites that
   are active, non-deleted, non-spam, and non-archived.
2. For every included site, inspect queued hooks, the oldest overdue timestamp, and
   evidence of the last execution.
3. Inspect `DISABLE_WP_CRON`, `ALTERNATE_WP_CRON`, automatic-updater disable flags,
   `WP_AUTO_UPDATE_CORE`, selected plugin/theme auto-updates, and vendor or safety
   filters.
4. Keep update-check scheduling, automatic installation, and mail delivery separate
   in the assessment. A successful update check does not prove installation or
   notification works.

Do not infer a failure from a missing standalone `wp_maybe_auto_update` event: the
installed WordPress version-check cron can invoke the auto-update action directly.
Confirm the installed scheduler's behavior before drawing conclusions.

## Verify the Hostinger and runtime surface

The selected website's hPanel cron list can be account-wide, and SSH may not expose
`crontab`. Verify current Hostinger API documentation at
<https://developers.hostinger.com> before relying on endpoints or fields. Observed
API shapes use `GET` and `POST` on
`/api/hosting/v1/accounts/{username}/cron-jobs`, exact-job `DELETE` on the nested
`/{uid}`, and `GET` on `/{uid}/output`; the observed `POST` fields are `time` and
`command`. These observations are not a substitute for current API documentation.

Before a mutation, privately snapshot exact job IDs, commands, and schedules. Use
placeholders and securely injected credentials in any procedure. After a partial
create or delete response, inspect live IDs before retrying; never blindly recreate
or remove account jobs.

Also verify the exact PHP binary and required extensions used by cron. They can differ
from the site's web PHP. Do not loosen web-PHP security settings so a coordinator can
spawn subprocesses; select and validate an appropriate cron runtime instead.

## Default scheduling strategy

Prefer one overlap-protected server job per network, initially every five minutes
when the workload permits. It should enumerate only the active sites from the
inventory and run native WordPress cron in isolated processes with explicit domain,
path, and HTTPS context. Resolve and verify the target blog ID before callbacks.

Preserve WordPress's native per-site locks. Separate hPanel rows for children are
optional, not required by this strategy. Do not change existing single-site guidance,
automatic-update choices, vendor safeguards, or traffic-triggered cron until the
replacement has proven coverage.

## Reliability and evidence

Check backlog types before enabling execution. Maintain private, bounded and rotated
status receipts and logs that omit event arguments, credentials, and other secrets.
For each cycle, record per-site completion or failure, remaining overdue count, and
timestamps. Captured provider output must be verified alongside those receipts.

Interpret the evidence carefully:

- A skipped overlap, partial cycle, or stale receipt is not success.
- Empty or transient-error provider output is not proof that cron failed.
- A manual probe, process exit code alone, or configured label is not successful
  scheduled execution.
- Private logs are not external monitoring or alerting.

Use a soft cycle budget and fair continuation when a whole-network cycle becomes
longer than its cadence. Do not kill a running update or payment job, and do not
starve individual sites. Review cadence and capacity whenever a full cycle no longer
fits the selected interval.

Avoid a raw trailing `#` annotation in a command when it can swallow a host-appended
output redirect. Use safely quoted metadata or another supported label mechanism,
then verify the resulting captured output.

## Safe cutover and rollback

1. Obtain scoped approval and privately preserve the current scheduler and relevant
   configuration state.
2. Probe each site's context without running due callbacks, and verify the network
   overlap lock.
3. Enable the replacement scheduler and observe a real scheduler-driven cycle for
   every included site.
4. Retire only the exact old parent job after that proof; preserve unrelated account
   jobs and existing update choices.
5. Only then disable traffic-triggered cron, and verify another scheduled cycle.

On a partial failure, retain working coverage and inspect current live job IDs before
retrying. Restore only the prior traffic-cron setting and exact approved scheduler
rows when required. Never overwrite unrelated later `wp-config.php` changes or use a
whole-account or whole-config restore.

## Completion record

Report the active sites covered, observed scheduler-driven cycles, overdue counts,
effective update policy, unrelated jobs preserved, and any remaining vendor or
notification limits. Do not claim completion until real scheduled execution has been
observed for the required sites.
