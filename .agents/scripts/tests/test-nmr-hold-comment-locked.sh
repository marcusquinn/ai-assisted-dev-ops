#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for locked-issue handling in nmr-hold-comment.yml.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit
WORKFLOW_FILE="${REPO_ROOT}/.github/workflows/nmr-hold-comment.yml"

node - "$WORKFLOW_FILE" <<'NODE'
const fs = require('node:fs');
const assert = require('node:assert/strict');

const workflowFile = process.argv[2];
const workflow = fs.readFileSync(workflowFile, 'utf8');
const marker = '          script: |\n';
const markerIndex = workflow.indexOf(marker);
assert.notEqual(markerIndex, -1, 'github-script block must exist');

const scriptLines = [];
for (const line of workflow.slice(markerIndex + marker.length).split('\n')) {
  if (line !== '' && !line.startsWith('            ')) break;
  scriptLines.push(line.startsWith('            ') ? line.slice(12) : line);
}
const script = scriptLines.join('\n');
const execute = new Function(
  'github',
  'context',
  'console',
  `return (async () => {\n${script}\n})();`
);

async function runScenario({ locked = false, comments = [], createError } = {}) {
  const calls = { paginate: 0, createComment: 0, logs: [] };
  const github = {
    paginate: async () => {
      calls.paginate += 1;
      return comments;
    },
    rest: {
      issues: {
        listComments: async () => comments,
        createComment: async () => {
          calls.createComment += 1;
          if (createError) throw createError;
        }
      }
    }
  };
  const context = {
    actor: 'test-actor',
    repo: { owner: 'owner', repo: 'repo' },
    payload: {
      issue: {
        number: 42,
        locked,
        author_association: 'MEMBER'
      }
    }
  };
  const testConsole = { log: message => calls.logs.push(message) };
  await execute(github, context, testConsole);
  return calls;
}

async function main() {
  const locked = await runScenario({ locked: true });
  assert.equal(locked.paginate, 0, 'locked snapshot must not list comments');
  assert.equal(locked.createComment, 0, 'locked snapshot must not create a comment');
  assert.match(locked.logs.join('\n'), /hold guidance is unnecessary/);

  const unlocked = await runScenario();
  assert.equal(unlocked.paginate, 1, 'unlocked issue must preserve paginated dedup');
  assert.equal(unlocked.createComment, 1, 'unlocked issue without guidance must post once');

  const deduplicated = await runScenario({
    comments: [{ body: '<!-- nmr-hold-guidance --> already posted' }]
  });
  assert.equal(deduplicated.paginate, 1, 'dedup must inspect all comments');
  assert.equal(deduplicated.createComment, 0, 'existing guidance must suppress the write');

  const lockRace = new Error('Request failed with status code 403');
  lockRace.status = 403;
  lockRace.response = {
    data: { message: 'Unable to create comment because issue is locked.' }
  };
  const concurrentLock = await runScenario({ createError: lockRace });
  assert.equal(concurrentLock.createComment, 1, 'concurrent lock occurs at the write');
  assert.match(concurrentLock.logs.join('\n'), /was locked before guidance could be posted/);

  for (const status of [401, 403, 404, 422, 500]) {
    const unrelated = new Error('Resource not accessible by integration');
    unrelated.status = status;
    await assert.rejects(
      runScenario({ createError: unrelated }),
      unrelated,
      `unrelated ${status} error must remain terminal`
    );
  }

  process.stdout.write('PASS: nmr hold guidance locked-issue regression scenarios\n');
}

main().catch(error => {
  process.stderr.write(`${error.stack || error}\n`);
  process.exitCode = 1;
});
NODE
