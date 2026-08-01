<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Release Artifact Provenance

Use this pattern when a repository publishes installable artifacts, container
images, update manifests, package indexes, checksums, or release catalogs from
GitHub Actions. The goal is unattended, independently verifiable publisher
provenance without a long-lived signing key.

## Default Pattern

1. Restrict publication to a reviewed protected branch or an expected release
   tag. Validate the exact ref before requesting an OIDC identity.
2. Build immutable artifacts from the reviewed source revision. Container
   references must use the resolved digest, never only a mutable tag.
3. Grant the signing job only the permissions it needs:
   `id-token: write`, `attestations: write`, and the narrowest required
   `contents`/`packages` permissions.
4. Pin `actions/attest-build-provenance` by full commit SHA. Attest the exact
   file bytes with `subject-path`, or the exact OCI subject name and digest with
   `subject-name` plus `subject-digest`.
5. Verify the emitted bundle before publication continues. Constrain
   verification to the repository, exact signer workflow, and already-validated
   source ref; do not accept repository ownership alone as sufficient identity.
6. Publish or promote only the verified artifact. Keep versions append-only and
   preserve digest-to-release evidence.
7. Verify the public artifact or registry digest again after publication. Record
   the verification command in the repository publishing runbook.

GitHub Actions obtains a short-lived signing certificate from its OIDC identity
and records Sigstore transparency evidence. Routine releases therefore require
no signing-key secret or operator attendance. Human authority remains necessary
for initial workflow/branch-policy review, consequential publication consent,
and trust-policy or keyless-identity changes.

## File Artifact Example

```yaml
permissions:
  attestations: write
  contents: read
  id-token: write

steps:
  - name: Attest release artifact
    id: attest-artifact
    uses: actions/attest-build-provenance@e8998f949152b193b063cb0ec769d69d929409be # v2.4.0
    with:
      subject-path: path/to/release-artifact

  - name: Verify exact attestation bundle
    env:
      GH_TOKEN: ${{ github.token }}
    run: |
      gh attestation verify path/to/release-artifact \
        --bundle "${{ steps.attest-artifact.outputs.bundle-path }}" \
        --repo "${GITHUB_REPOSITORY}" \
        --signer-workflow "${GITHUB_REPOSITORY}/.github/workflows/release.yml" \
        --source-ref refs/heads/main
```

Replace the workflow path and expected ref with repository-owned constants. For
tag publication, first validate the exact allowed tag pattern and then verify
the same `GITHUB_REF`; never let untrusted inputs choose the signer identity or
expected ref.

## OCI Image Example

```yaml
- name: Attest immutable image
  id: attest-image
  uses: actions/attest-build-provenance@e8998f949152b193b063cb0ec769d69d929409be # v2.4.0
  with:
    subject-name: ${{ env.IMAGE_REPOSITORY }}
    subject-digest: ${{ steps.build.outputs.digest }}
    push-to-registry: true

- name: Verify exact image attestation
  env:
    GH_TOKEN: ${{ github.token }}
    IMAGE_DIGEST: ${{ steps.build.outputs.digest }}
  run: |
    gh attestation verify "oci://${IMAGE_REPOSITORY}@${IMAGE_DIGEST}" \
      --bundle "${{ steps.attest-image.outputs.bundle-path }}" \
      --repo "${GITHUB_REPOSITORY}" \
      --signer-workflow "${GITHUB_REPOSITORY}/.github/workflows/release.yml" \
      --source-ref refs/heads/main
```

Authenticate to the registry when verification requires it. Verify the digest
subject, not the release tag. Keep `push-to-registry: true` when operators need
to retrieve the attestation with the OCI artifact.

## Existing Releases and Other Ecosystems

- Add a no-version-bump path that attests the current public catalog or artifact
  once, so adopting provenance does not require fabricating a release.
- Prefer native trusted publication in addition to artifact attestations, such
  as npm OIDC provenance. Do not replace an ecosystem's stronger consumer-side
  verification with a detached attestation that clients ignore.
- For multiple artifacts, attest a deterministic archive or each independently
  consumed file. Do not attest a mutable directory whose packaged bytes differ
  from the public download.
- Preserve platform signing requirements (for example notarization or package
  signing). Sigstore provenance identifies the build; it does not replace
  executable trust mechanisms enforced by an operating system.

## Security Boundary

An attestation makes tampering detectable only when somebody verifies it against
the expected identity. It does not make a compromised release workflow honest,
prevent a trusted workflow from building malicious input, or force downstream
clients to reject an unsigned update. Protect the workflow and branch, pin all
third-party actions, minimize token permissions, and state whether consumers
enforce the attestation or it currently provides audit evidence only.

Checksums published beside an artifact are not a substitute: compromise of the
same host can replace both. Update systems that need rollback/freeze protection
also require trusted version/expiry policy (for example a TUF-style design), not
only a signature over the latest manifest.
