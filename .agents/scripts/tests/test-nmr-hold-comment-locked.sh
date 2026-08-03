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
  'core',
  `return (async () => {\n${script}\n})();`
);

async function runScenario({
  locked = false,
  comments = [],
  createError,
  association = 'CONTRIBUTOR',
  userType = 'User',
  permission = 'read',
  labels = [],
  removeError
} = {}) {
  const calls = {
    paginate: 0,
    createComment: 0,
    addLabels: 0,
    removeLabel: 0,
    logs: [],
    warnings: []
  };
  const github = {
    request: async () => ({ data: { permission } }),
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
        },
        addLabels: async () => {
          calls.addLabels += 1;
        },
        removeLabel: async () => {
          calls.removeLabel += 1;
          if (removeError) throw removeError;
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
        author_association: association,
        user: { login: 'issue-author', type: userType },
        labels: labels.map(name => ({ name }))
      }
    }
  };
  const testConsole = { log: message => calls.logs.push(message) };
  const core = { warning: message => calls.warnings.push(message) };
  await execute(github, context, testConsole, core);
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

  const trustedOwner = await runScenario({ association: 'OWNER' });
  assert.equal(trustedOwner.addLabels, 1, 'trusted OWNER NMR must become a structural hold');
  assert.equal(trustedOwner.removeLabel, 1, 'trusted OWNER NMR must be removed');
  assert.equal(trustedOwner.paginate, 0, 'trusted normalization must not post external approval guidance');

  const trustedCollaborator = await runScenario({
    association: 'COLLABORATOR',
    permission: 'write'
  });
  assert.equal(trustedCollaborator.addLabels, 1, 'write collaborator NMR must become a structural hold');
  assert.equal(trustedCollaborator.removeLabel, 1, 'write collaborator NMR must be removed');

  const externalOriginBot = await runScenario({
    association: 'NONE',
    userType: 'Bot',
    labels: ['external-contributor']
  });
  assert.equal(externalOriginBot.addLabels, 0, 'external-origin bot NMR must not become an internal hold');
  assert.equal(externalOriginBot.removeLabel, 0, 'external-origin bot NMR must remain live');
  assert.equal(externalOriginBot.createComment, 1, 'external-origin bot NMR must receive approval guidance');

  const failedRemoval = new Error('rate limited');
  failedRemoval.status = 429;
  await assert.rejects(
    runScenario({ association: 'MEMBER', removeError: failedRemoval }),
    failedRemoval,
    'trusted normalization failure must remain observable'
  );

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
