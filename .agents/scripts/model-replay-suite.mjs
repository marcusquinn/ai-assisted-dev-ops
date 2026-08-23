// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { TIERS } from "./model-replay-core.mjs";

function suiteEntriesFor(corpus, suite) {
  const active = corpus.manifest.cases.filter((entry) => entry.active !== false);
  return suite === "full" ? active : active.filter((entry) => entry.quick === true);
}

function assertSuiteSize(corpus, suite, suiteEntries) {
  const expectedSize = Number(corpus.manifest.suites?.[suite]);
  if (!Number.isInteger(expectedSize) || expectedSize < 1) {
    throw new Error(`Corpus does not define a valid ${suite} suite size`);
  }
  if (suiteEntries.length !== expectedSize) {
    throw new Error(`${suite} suite requires ${expectedSize} cases; found ${suiteEntries.length}`);
  }
  return expectedSize;
}

function assertBalancedSuite(corpus, suite, suiteEntries, expectedSize) {
  const combinationCount = corpus.manifest.profiles.length * TIERS.length;
  if (expectedSize < combinationCount) return;
  if (expectedSize % combinationCount !== 0) {
    throw new Error(`${suite} suite size must balance profiles across all tiers`);
  }
  const expectedPerCombination = expectedSize / combinationCount;
  for (const profile of corpus.manifest.profiles) {
    for (const tier of TIERS) {
      const actual = suiteEntries.filter((entry) => (
        entry.profile === profile && entry.expected_tier === tier
      )).length;
      if (actual !== expectedPerCombination) {
        throw new Error(
          `${suite} suite requires ${expectedPerCombination} ${profile}/${tier} cases; found ${actual}`,
        );
      }
    }
  }
}

function canaryEntries(corpus, suiteEntries) {
  const selected = [];
  for (const profile of corpus.manifest.profiles) {
    const match = suiteEntries.find(
      (entry) => entry.profile === profile && entry.expected_tier === "simple",
    );
    if (!match) throw new Error(`Canary suite lacks a simple case for profile ${profile}`);
    selected.push(match);
  }
  return selected;
}

function sweepEntries(suiteEntries) {
  const selected = suiteEntries.filter((entry) => entry.discriminator === true);
  if (selected.length === 0) throw new Error("Sweep stage requires discriminator cases");
  return selected;
}

export function selectSuiteEntries(corpus, suite, stage) {
  const suiteEntries = suiteEntriesFor(corpus, suite);
  const expectedSize = assertSuiteSize(corpus, suite, suiteEntries);
  assertBalancedSuite(corpus, suite, suiteEntries, expectedSize);
  if (stage === "canary") return canaryEntries(corpus, suiteEntries);
  if (stage === "sweep") return sweepEntries(suiteEntries);
  return suiteEntries;
}

export function effortsFor(candidate, stage) {
  if (stage === "sweep" || stage === "confirm") return candidate.efforts;
  return [candidate.primary_effort];
}

export function repeatsFor(candidate, stage) {
  if (stage !== "confirm") return 1;
  const repeats = Number(candidate.confirmation_repeats ?? 3);
  if (!Number.isInteger(repeats) || repeats < 2 || repeats > 5) {
    throw new Error(`Candidate ${candidate.model} confirmation_repeats must be 2..5`);
  }
  return repeats;
}
