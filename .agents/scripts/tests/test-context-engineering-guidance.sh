#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

repo_root=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
architecture="$repo_root/.agents/aidevops/architecture.md"
self_purpose="$repo_root/.agents/aidevops/purpose.md"
self_improvement="$repo_root/.agents/reference/self-improvement.md"
failures=0

assert_contains() {
	local description="$1"
	local needle="$2"
	local file="$3"

	if ! rg -Fq -- "$needle" "$file"; then
		printf 'FAIL: %s\n' "$description" >&2
		failures=$((failures + 1))
		return 0
	fi

	printf 'PASS: %s\n' "$description"
	return 0
}

assert_absent() {
	local description="$1"
	local needle="$2"
	local file="$3"

	if rg -Fq -- "$needle" "$file"; then
		printf 'FAIL: %s\n' "$description" >&2
		failures=$((failures + 1))
		return 0
	fi

	printf 'PASS: %s\n' "$description"
	return 0
}

assert_contains \
	"architecture assigns open-ended decisions to model judgment" \
	"Use model judgment for open-ended decisions" \
	"$architecture"
assert_contains \
	"architecture retains deterministic enforcement" \
	"Deterministic hooks, validators, wrappers, and CI checks should enforce syntax" \
	"$architecture"
assert_contains \
	"architecture distinguishes judgment from mechanics" \
	"If reasonable models could choose differently" \
	"$architecture"
assert_contains \
	"architecture routes instruction changes through Agent Review" \
	".agents/tools/build-agent/agent-review.md" \
	"$architecture"
assert_absent \
	"architecture no longer rejects every script-based fix" \
	"Fix adds a \`.sh\` file or state mechanism" \
	"$architecture"
assert_absent \
	"architecture no longer defaults every model error to prose" \
	"When the agent errs, fix the guidance — not a new script" \
	"$architecture"

assert_contains \
	"canonical purpose defines the 100x target as an ambition" \
	"guaranteed or measured result" \
	"$self_purpose"
assert_contains \
	"architecture inherits the canonical purpose" \
	".agents/aidevops/purpose.md" \
	"$architecture"

assert_contains \
	"self-improvement work stays within established authority" \
	"within the established objective, authority" \
	"$self_improvement"
assert_contains \
	"safe in-scope process defects are repaired now" \
	"repair safe, authorised, in-scope process defects" \
	"$self_improvement"
assert_contains \
	"self-improvement selects deterministic enforcement for mechanics" \
	"Select deterministic enforcement for reproducible mechanics" \
	"$self_improvement"
assert_contains \
	"continuation authority is bounded" \
	"authorises continued progress on the current" \
	"$self_improvement"
assert_contains \
	"publication and consequential actions remain excluded" \
	"This does not authorise unrelated scope" \
	"$self_improvement"
assert_absent \
	"self-improvement no longer defers every response to an issue" \
	"Response: file an issue" \
	"$self_improvement"
assert_absent \
	"self-improvement no longer rejects deterministic alternatives" \
	"no deterministic alternative" \
	"$self_improvement"
assert_contains \
	"self-improvement keeps repository knowledge distinct from forge conversations" \
	"portable execution conversations, not the sole record" \
	"$self_improvement"

# Capture generated delivery without credentials, models, or real user mirrors.
python3 - "$repo_root" <<'PY'
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

repo = Path(sys.argv[1])
scripts = repo / '.agents/scripts'

def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, scripts / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

with tempfile.TemporaryDirectory(prefix='primary-delivery-') as temporary:
    home = Path(temporary)
    agents = home / '.aidevops/agents'
    agents.mkdir(parents=True)
    for name in ('AGENTS.md', 'build-plus.md', 'seo.md', 'content.md'):
        shutil.copyfile(repo / '.agents' / name, agents / name)
    shutil.copyfile(repo / 'VERSION', agents / 'VERSION')
    config_path = home / '.config/opencode/opencode.json'
    config_path.parent.mkdir(parents=True)
    custom = {'description': 'user-owned', 'prompt': 'user workflow', 'mode': 'primary'}
    initial = {'instructions': ['personal.md'], 'agent': {'Personal': custom}, 'username': 'fixture'}
    env = {**os.environ, 'HOME': str(home), 'XDG_CONFIG_HOME': str(home / '.config')}
    for route, args in (
        ('unified', ['agent-discovery.py', 'opencode', 'opencode-json']),
        ('compatibility', ['opencode-agent-discovery.py']),
    ):
        config_path.write_text(json.dumps(initial))
        for _ in range(2):
            result = subprocess.run([sys.executable, str(scripts / args[0]), *args[1:]],
                                    env=env, capture_output=True, text=True, timeout=30)
            assert result.returncode == 0, f'{route} discovery failed'
        config = json.loads(config_path.read_text())
        assert config['instructions'] == ['personal.md', str(agents / 'AGENTS.md')]
        assert config['agent']['Personal'] == custom
        assert config['username'] == 'fixture'
        for profile, name in [('Build+', 'build-plus'), ('SEO', 'seo'), ('Content', 'content')]:
            source = agents / f'{name}.md'
            prompt = config['agent'][profile]['prompt']
            assert prompt == f'{{file:~/.aidevops/agents/{name}.md}}'
            assert source.read_text().strip(), 'canonical source must not be a placeholder'
            digest = hashlib.sha256(source.read_bytes()).hexdigest()
            print(f'PASS: {route} profile={profile} source={name}.md sha256={digest} hooks=unavailable')
        # Missing deployed sources must not silently erase the existing core fallback.
        core = agents / 'AGENTS.md'
        core.rename(agents / 'core.saved')
        result = subprocess.run([sys.executable, str(scripts / args[0]), *args[1:]],
                                env=env, capture_output=True, text=True, timeout=30)
        assert result.returncode == 0
        assert str(core) in json.loads(config_path.read_text())['instructions']
        (agents / 'core.saved').rename(core)

    # Probe the installed native loader, without plugins, providers, inherited
    # config overrides or credentials. This is not a model invocation.
    binary = shutil.which('opencode')
    if binary:
        native_env = {'PATH': os.environ['PATH'], 'HOME': str(home),
                      'OPENCODE_PURE': '1', 'OPENCODE_DISABLE_DEFAULT_PLUGINS': '1',
                      'OPENCODE_DISABLE_EXTERNAL_SKILLS': '1'}
        for key, directory in [('CONFIG', '.config'), ('CACHE', '.cache'),
                               ('DATA', '.local/share'), ('STATE', '.local/state')]:
            native_env[f'XDG_{key}_HOME'] = str(home / directory)
        samples = [('Build+', 'build-plus'), ('SEO', 'seo'), ('Content', 'content')]
        minimal = {'agent': {key: config['agent'][key] for key, _ in samples},
                   'instructions': [str(agents / 'AGENTS.md')], 'plugin': [], 'mcp': {}}
        config_path.write_text(json.dumps(minimal))
        for profile, name in samples:
            result = subprocess.run([binary, 'debug', 'agent', profile], cwd=home,
                                    env=native_env, capture_output=True, text=True, timeout=90)
            assert result.returncode == 0, f'native loader failed: {profile}'
            delivered = json.loads(result.stdout)['prompt'].strip()
            assert delivered == (agents / f'{name}.md').read_text().strip()
            print(f'PASS: native loader expanded {profile} canonical source without plugin hooks')
        (agents / 'seo.md').unlink()
        missing = subprocess.run([binary, 'debug', 'agent', 'SEO'], cwd=home,
                                 env=native_env, capture_output=True, text=True, timeout=90)
        assert missing.returncode != 0, 'missing selected source must fail rather than silently omit knowledge'
        shutil.copyfile(repo / '.agents/seo.md', agents / 'seo.md')
    else:
        print('SKIP: native OpenCode capture (binary unavailable); generator contracts tested')

    # Native Codex preload must preserve explicit user override precedence.
    codex = load('delivery_codex', 'codex-setup.py')
    codex_home = home / '.codex'
    codex_home.mkdir()
    (codex_home / 'AGENTS.md').write_text('Personal instructions\n')
    override = codex_home / 'AGENTS.override.md'
    override.write_text('Explicit user override\n')
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        codex.guidance(codex_home, agents)
        codex.guidance(codex_home, agents)
    assert 'takes precedence' in output.getvalue()
    assert override.read_text() == 'Explicit user override\n'
    text = (codex_home / 'AGENTS.md').read_text()
    assert text.count(codex.START) == 1 and 'Personal instructions' in text

    launcher = load('delivery_launcher', 'runtime-launcher.py')
    launcher.ROOT = agents
    for name in ('build-plus', 'seo', 'content'):
        source = agents / f'{name}.md'
        prompt = launcher.guidance(name, source)
        assert str(agents / 'AGENTS.md') in prompt and str(source) in prompt
        for runtime in ('codex', 'claude-code'):
            args = launcher.agent_args(runtime, name, source, prompt, True)
            assert prompt in args or any(json.dumps(prompt) in value for value in args)
    print('PASS: native Codex shadow warning, repeat setup and launcher required-load contracts')
PY

if [[ "$failures" -ne 0 ]]; then
	printf '\n%d context-engineering guidance check(s) failed\n' "$failures" >&2
	exit 1
fi

printf '\nAll context-engineering guidance checks passed\n'
