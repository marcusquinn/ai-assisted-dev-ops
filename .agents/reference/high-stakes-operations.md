<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# High-Stakes Operations Taxonomy

Defines which operations trigger parallel model verification before execution (plan p035, t1364.1). Agent contextual judgment takes precedence over pattern matching in `configs/verification-triggers.json`.

## Risk Levels and Gate Behaviours

| Level | Policy | Gate options |
|-------|--------|--------------|
| **critical** | Always verify. Cannot be disabled per-repo. | block (halt until pass; disagreement → opus/user) |
| **high** | Verify by default. Disable via `.aidevops.json` or `repos.json`. | warn (log, allow proceed) |
| **medium** | Opt-in only. | log (silent audit trail) |

## Operation Categories

### Git Destructive — critical

| Operation | Example | Gate |
|-----------|---------|------|
| Force push | `git push --force`, `--force-with-lease` | block |
| Hard reset | `git reset --hard` | block |
| Remote branch deletion | `git push origin --delete`, `git branch -D` + push | block |
| History rewrite | `git rebase` on pushed commits, `git filter-branch` | block |
| Remote tag deletion | `git push --delete origin v1.0.0` | block |
| Submodule removal | `git submodule deinit`, `git rm <submodule>` | warn |

**Context:** `main`/`master`/`release/*` branches increase severity.

### Production Deployments — critical

| Operation | Example | Gate |
|-----------|---------|------|
| Production deploy | `coolify deploy --env production`, `vercel --prod` | block |
| DNS changes | A/AAAA/CNAME records, nameserver changes | block |
| SSL/TLS changes | Replacing or revoking certificates | block |
| Load balancer config | Routing rules, backend pools | block |
| Container orchestration | `docker stack deploy`, Kubernetes apply to prod | block |
| Rollback | `coolify rollback`, `vercel rollback` | warn |

**Context:** "production", "prod", `NODE_ENV=production`. Staging/preview = lower risk.

### Data Migrations — high

| Operation | Example | Gate |
|-----------|---------|------|
| Destructive schema migration | `DROP TABLE`, `DROP COLUMN`, `ALTER TABLE ... DROP` | block |
| Bulk data modification | `UPDATE ... WHERE` >1000 rows, `DELETE FROM` | block |
| Database restore/overwrite | Restoring backup over live database | block |
| Additive schema migration | `CREATE TABLE`, `ADD COLUMN` | warn |
| Data export/dump | `pg_dump`, `mysqldump` | log |
| Index changes | `CREATE INDEX`, `DROP INDEX` | log |

**Context:** `--production` flags, production connection strings, migration files with "down" in name.

### Security-Sensitive Changes — high

| Operation | Example | Gate |
|-----------|---------|------|
| Permission/ACL changes | `chmod 777`, IAM policies, RBAC rules | block |
| Firewall rule changes | Opening ports, security groups | block |
| Encryption key management | Generating, rotating, or deleting keys | block |
| Secret exposure risk | Committing `.env`, `credentials.json`, private keys | block |
| Credential rotation | API keys, passwords, tokens | warn |
| Auth config changes | OAuth providers, SSO config, MFA settings | warn |

**Context:** `*.pem`, `*.key`, `.env*`, `credentials.*`, `secrets.*`; `chmod`, `chown`, `iptables`, `ufw`, `security-group`.

### Financial Operations — high

| Operation | Example | Gate |
|-----------|---------|------|
| Payment gateway config | Stripe/RevenueCat webhook URLs, API key changes | block |
| Pricing changes | Product prices, subscription tiers | block |
| Refund processing | Refunds, credits, adjustments | warn |
| Invoice generation | Creating or modifying invoice templates | warn |
| Financial report export | Exporting transaction data | log |

**Context:** Payment/billing directories, Stripe/RevenueCat API calls, currency amounts.

### Infrastructure Destruction — critical

| Operation | Example | Gate |
|-----------|---------|------|
| Resource deletion | `terraform destroy`, `pulumi destroy` | block |
| Volume/disk deletion | Persistent volumes, EBS volumes | block |
| Account/org changes | Deleting cloud accounts, changing org ownership | block |
| Backup deletion | Removing snapshots, retention policy changes | block |
| Network destruction | Deleting VPCs, subnets, peering connections | block |

**Context:** Terraform/Pulumi state files, `destroy`/`delete` in infrastructure commands, `--force` flags.

## Verification Policy Schema

Per-repo config in `.aidevops.json` or `repos.json`:

```json
{
  "verification": {
    "enabled": true,
    "default_gate": "warn",
    "overrides": {
      "git_destructive": { "gate": "block", "enabled": true },
      "production_deploy": { "gate": "block", "enabled": true },
      "data_migration": { "gate": "warn", "enabled": true },
      "security_sensitive": { "gate": "warn", "enabled": true },
      "financial": { "gate": "warn", "enabled": false },
      "infrastructure_destruction": { "gate": "block", "enabled": true }
    },
    "cross_provider": true,
    "verifier_tier": "standard",
    "escalation_tier": "thinking"
  }
}
```

Fields: `enabled` (master switch), `default_gate` (fallback gate), `overrides`
(per-category), `cross_provider` (prefer different provider), `verifier_tier`
(default: `standard`), `escalation_tier` (default: `thinking`, used when
primary and verifier disagree).

## Trigger Detection and Integration

Detection mechanisms (in priority order):
1. **Agent judgment** — overrides pattern matching in both directions
2. **Context signals** — branch name, file paths, env vars, connection strings
3. **Command pattern matching** — regex in `configs/verification-triggers.json`

Integration:
- **pre-edit-check.sh** — sets `REQUIRES_VERIFICATION=1` on detection
- **Verification agent** (t1364.2) — returns verdict (proceed/warn/block)
- **Pipeline integration** (t1364.3) — wires verification into dispatch/execution

## Related Files

- `configs/verification-triggers.json` — machine-readable trigger patterns
- `scripts/pre-edit-check.sh` — branch protection and high-stakes detection
- `tools/context/model-routing.md` — model tier definitions
- `configs/model-routing-table.json` — provider/model resolution
- `reference/orchestration.md` — orchestration architecture
