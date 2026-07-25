<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Reasoning Brief Format (tier:thinking)

For tasks that must plan, design, refactor, or resolve consequential trade-offs. Define the decision space and evidence without manufacturing implementation certainty.

## Format

```markdown
### Problem

{What needs to be solved, why the obvious approach may be wrong}

### Constraints

- {Hard constraint — must hold}
- {Soft constraint — prefer but can trade off}

### Prior Art

- `path/to/similar.ts` — {how a similar problem was solved}
- {External reference if applicable}

### Evidence to Inspect

- `{path or source}` — {question this evidence can answer}

### Decisions to Make

- {Decision, viable options, trade-offs, and who/what has authority to choose}

### Non-Goals

- {Explicitly excluded outcome or compatibility boundary}

### Acceptance Criteria

- [ ] {Testable criterion}
- [ ] {Testable criterion}
```

## Key principles

- **Problem-first**: Describe the challenge, not the solution
- **Constraints matter**: Hard constraints (must hold) vs soft constraints (prefer)
- **Prior art**: Reference similar solutions in the codebase
- **Decision-oriented**: Name unresolved choices, evidence, trade-offs, and authority
- **No speculative scaffolding**: Do not invent likely files or code skeletons before the design determines them; use evidence-backed "not yet knowable" where necessary
- **Testable criteria**: Each criterion must be verifiable, not subjective
