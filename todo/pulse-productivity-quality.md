# Remove productivity-recovery quality regressions before release

## What

Remove the four new Qlty smells reported on #31347 before releasing #31343.
This is an interactive follow-up in the same user-authorized release lifecycle.

## Reproducer

Qlty 0.643.0 reports boolean-logic, file-complexity and function-complexity in
`.agents/scripts/gh_transport_budget.py`, and boolean-logic in
`.agents/scripts/pulse-check-queue-scan.py`. The report is verified locally.

## How and Files Scope

Extract bounded recovery predicates and read-only diagnostics into
`.agents/scripts/gh_transport_recovery.py`, retain the public Budget interface,
and simplify queue eligibility conditions. Update the existing hermetic shim
fixture to copy the required module. No policy change or threshold override.

## Verification

Run existing transport budget (23 cases), shim (159 assertions), Pulse Check
(122 assertions), Qlty targeted smells/check and scoped ShellCheck. Preserve
reserve cadence, alias merging, request identity and read-only diagnostics.
