#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-knowledge-social-registry.sh — Deterministic provider registration tests

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}/../scripts"
HELPER="${SCRIPTS_DIR}/knowledge-social-helper.sh"
REGISTRY="${SCRIPTS_DIR}/knowledge_social_registry.py"
PASS=0
FAIL=0

assert_eq() {
	local description="$1"
	local actual="$2"
	local expected="$3"
	if [[ "$actual" == "$expected" ]]; then
		PASS=$((PASS + 1))
		printf '  PASS  %s\n' "$description"
	else
		FAIL=$((FAIL + 1))
		printf '  FAIL  %s (expected=%s actual=%s)\n' "$description" "$expected" "$actual"
	fi
	return 0
}

printf 'Social provider registry tests\n'

registry_summary=$(
	python3 - "$REGISTRY" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("social_registry", sys.argv[1])
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)

expected = {
    "bluesky": ("live",),
    "binance-square": ("no-route",),
    "discord": ("live",),
    "forem": ("live",),
    "github": ("live",),
    "google-business-profile": ("live",),
    "gumroad": ("live",),
    "lemmy": ("live",),
    "mastodon": ("live",),
    "miniflux": ("live",),
    "nextcloud-talk": ("live",),
    "readwise-reader": ("live",),
    "signal": ("inspect", "manual-import", "status"),
    "slack": ("archive", "live"),
    "stack-exchange": ("live",),
    "telegram": ("archive", "event", "status"),
    "whatsapp": ("archive", "event"),
}
actual = {
    provider: tuple(sorted(mode for mode, _prefix in item.modes))
    for provider, item in module.PROVIDERS.items()
}
if actual != expected:
    raise SystemExit(f"unexpected registry: {actual}")

forward = module.register_specs(module.PROVIDER_SPECS)
reverse = module.register_specs(reversed(module.PROVIDER_SPECS))
if tuple(forward[0]) != tuple(reverse[0]) or forward[1] != reverse[1]:
    raise SystemExit("registration depends on input order")

for alias, provider in {
    "atproto": "bluesky",
    "dev-community": "forem",
    "dev.to": "forem",
    "gbp": "google-business-profile",
    "reader": "readwise-reader",
    "stackexchange": "stack-exchange",
    "whats-app": "whatsapp",
}.items():
    if module.resolve_provider(alias).provider != provider:
        raise SystemExit(f"alias {alias} did not resolve to {provider}")

collision = module.ProviderSpec(
    "other-provider", ("dev-community",), "unused.py", (("live", ()),)
)
try:
    module.register_specs((*module.PROVIDER_SPECS, collision))
except module.ProviderRegistryError:
    pass
else:
    raise SystemExit("duplicate alias was accepted")

try:
    module.resolve_provider("unknown-provider")
except module.ProviderRegistryError:
    pass
else:
    raise SystemExit("unknown provider used a fallback")

print("17:order-independent:aliases-exact:collisions-rejected:no-fallback")
PY
)
assert_eq "all merged provider outcomes register deterministically" \
	"$registry_summary" "17:order-independent:aliases-exact:collisions-rejected:no-fallback"

provider_count=$("$HELPER" providers | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
assert_eq "helper exposes the complete provider registry" "$provider_count" "17"

forem_resolution=$("$HELPER" provider-resolve --provider dev-community |
	python3 -c 'import json,sys; data=json.load(sys.stdin); print(data["provider"] + ":" + ",".join(data["modes"]))')
assert_eq "DEV Community resolves only to the Forem family" "$forem_resolution" "forem:live"

if "$HELPER" provider-run --provider binance-square --mode no-route >/dev/null 2>&1; then
	assert_eq "no-route outcomes cannot execute" accepted rejected
else
	assert_eq "no-route outcomes cannot execute" rejected rejected
fi

if "$HELPER" provider-run --provider unknown-provider --mode live >/dev/null 2>&1; then
	assert_eq "unknown providers cannot fall back" accepted rejected
else
	assert_eq "unknown providers cannot fall back" rejected rejected
fi

if "$HELPER" provider-run --provider slack --mode unsupported >/dev/null 2>&1; then
	assert_eq "unsupported provider modes fail closed" accepted rejected
else
	assert_eq "unsupported provider modes fail closed" rejected rejected
fi

forem_help=$("$HELPER" provider-run --provider dev.to --mode live -- --help 2>&1)
if [[ "$forem_help" == *"Collect one bounded, read-only Forem account stream"* ]]; then
	assert_eq "allowlisted aliases execute only their canonical local adapter" canonical canonical
else
	assert_eq "allowlisted aliases execute only their canonical local adapter" unexpected canonical
fi

if rg -n 'operations|outbound|publish|send|trade|wallet|payment|listing.*write' "$REGISTRY" >/dev/null; then
	assert_eq "registry has no outbound mutation target" reachable unreachable
else
	assert_eq "registry has no outbound mutation target" unreachable unreachable
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
