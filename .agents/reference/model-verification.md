<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Parallel Model Verification (t1364)

High-stakes operations are verified by a second model before execution.
This catches single-model hallucinations before destructive operations cause
irreversible damage. Different providers have different failure modes, so
correlated errors are rare. Verification is targeted — not every operation,
only those matching the risk taxonomy.

## Usage

- Before destructive operations (force push, DB drop, production deploy, secret exposure): run `verify-operation-helper.sh check --operation "cmd"`. If risk is critical/high, run `verify-operation-helper.sh verify --operation "cmd" --risk-tier "critical"` and respect the result.
- pre-edit-check.sh accepts `--verify-op "command"` to gate operations at the pre-edit stage.
- dispatch.sh automatically screens task descriptions via `check_task_high_stakes()` before committing workers.
- Verification is opt-out (`VERIFY_ENABLED=false`) not opt-in. High-stakes operations are verified by default.
- Verification requests the `simple` workload tier by default; runtime routing
  selects the cheapest available approved model for that tier.
- When verification is unavailable (no verifier model reachable): critical operations are blocked in headless mode, warned in interactive mode. Non-critical operations proceed.
