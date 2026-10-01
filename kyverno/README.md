# Kyverno: verify attestations at deploy time

`verify.sh` and `.github/workflows/verify.yml` check the image's attestations
*after* the build. Nothing stops someone deploying an image that was never
checked, or one built somewhere else and pushed under the same name. These
Kyverno policies run the same checks inside the cluster's admission path, so
an image that doesn't verify can't run at all.

| File | What it enforces |
|---|---|
| `require-slsa-provenance.yaml` | A SLSA v1 provenance attestation signed by this repo's `build.yml` (main or `v*` tag) via GitHub OIDC + Sigstore. The provenance must also say the build ran on a GitHub-hosted runner, and the repo/owner numeric IDs must match. |
| `require-sbom-attestation.yaml` | A signed SPDX 2.3 SBOM from the same signer, and no package on a deny list (example: the xz-utils backdoor versions). |
| `examples/workloads.yaml` | A Deployment that should be admitted, plus an unrelated Pod that the policies ignore. |

Both are `ImageValidatingPolicy` resources (`policies.kyverno.io/v1`), which
need **Kyverno ≥ 1.19**. On older clusters, the legacy equivalent is a
`ClusterPolicy` with `verifyImages[].type: SigstoreBundle`.

## How it works

```
kubectl apply ─▶ API server ─▶ Kyverno MUTATING webhook
                                 │  resolve :latest → @sha256:…  (mutateDigest)
                                 ▼
                               Kyverno VALIDATING webhook
                                 │  1. fetch Sigstore bundles from GHCR
                                 │     (OCI referrers; GHCR's sha256-<digest> tag fallback)
                                 │  2. verify signature → Fulcio root (via Sigstore TUF)
                                 │     + Rekor inclusion proof
                                 │  3. cert SAN  == …/build.yml@refs/(heads/main|tags/v*)
                                 │     cert issuer == token.actions.githubusercontent.com
                                 │  4. in-toto subject digest == image digest
                                 │  5. CEL checks on the predicate (runner, repo IDs, SBOM)
                                 ▼
                               admit (pinned to digest)  or  deny
```

Here's how each part maps to what you already have:

| `verify.yml` (cosign) | Kyverno policy |
|---|---|
| `docker buildx imagetools inspect` → digest | `mutateDigest: true` + `verifyDigest: true` |
| `--certificate-oidc-issuer` | `attestors[].cosign.keyless.identities[].issuer` |
| `--certificate-identity-regexp` | `…identities[].subjectRegExp` (tightened to main / `v*` tags) |
| `--type slsaprovenance1` | `attestations[].intoto.type: https://slsa.dev/provenance/v1` |
| `--type https://spdx.dev/Document/v2.3` | `attestations[].intoto.type: https://spdx.dev/Document/v2.3` |
| *(not checked)* | CEL `validations` on the attestation contents |

### Why check the predicate if the signature is already pinned?

The certificate tells you **who** signed: this repo's `build.yml`. The
predicate tells you **how** the image was built. Two things in the predicate
are worth enforcing:

- **`runner_environment == 'github-hosted'`**: this is SLSA Build L3's
  isolation requirement. A self-hosted runner gets the same OIDC identity, so
  the signature check alone would accept it.
- **`repository_id` / `repository_owner_id`**: names can be deleted and
  registered again by someone else, but these numeric IDs can't. Pinning them
  stops an attacker from recreating `falconcrwd/slsademo` and signing their
  own image under an identical SAN.

### Why the SBOM deny list?

The SBOM is signed, so Kyverno can trust it as a list of what's inside the
image without scanning the image again. When an advisory like CVE-2024-3094
lands, add the bad `name@version` to `variables.deniedPackages` and every new
deploy is checked against it. Pods that are already running aren't evicted.
The check runs the next time they're admitted, for example on a rollout.

## Install

```bash
kubectl apply -f kyverno/require-slsa-provenance.yaml \
              -f kyverno/require-sbom-attestation.yaml
kubectl get imagevalidatingpolicies          # READY should be true
```

To roll out without blocking anything, change `validationActions: [Deny]` to
`[Audit]` first. Then watch `kubectl get policyreports -A` before switching to
Deny.

## Try it

```bash
# Admitted, and pinned to the verified digest:
kubectl apply -f kyverno/examples/workloads.yaml
kubectl get deploy slsademo -o jsonpath='{.spec.template.spec.containers[0].image}'
# ghcr.io/falconcrwd/slsademo@sha256:…           (already pinned in the example, so left as-is)
# Had it been written as :latest, Kyverno would have rewritten it to
# ghcr.io/falconcrwd/slsademo:latest@sha256:…    (tag kept; the runtime pulls by digest)

# Denied: an image pushed under the same name without going through build.yml
docker build -t ghcr.io/falconcrwd/slsademo:unsigned . && docker push ghcr.io/falconcrwd/slsademo:unsigned
kubectl run bad --image=ghcr.io/falconcrwd/slsademo:unsigned
# error: … image has no SLSA v1 provenance attestation signed by falconcrwd/slsademo/.github/workflows/build.yml …
```

### Offline, with the Kyverno CLI

The CLI runs only the validation phase and skips the tag→digest mutation. So
reference the image by digest, or `verifyDigest` will reject it first:

```bash
DIGEST=$(docker buildx imagetools inspect ghcr.io/falconcrwd/slsademo:latest --format '{{.Manifest.Digest}}')
kubectl run slsademo --image="ghcr.io/falconcrwd/slsademo@${DIGEST}" --dry-run=client -o yaml > /tmp/pod.yaml
kyverno apply kyverno/require-slsa-provenance.yaml kyverno/require-sbom-attestation.yaml --resource /tmp/pod.yaml
# pass: 2, fail: 0, warn: 0, error: 0, skip: 0
```

## Operational notes

- **Network egress.** The Kyverno admission controller must be able to reach
  `ghcr.io`, `tuf-repo-cdn.sigstore.dev` (Fulcio/Rekor trust roots), and
  `rekor.sigstore.dev`. On a cold cache, the first verification can take
  several seconds. That's why `timeoutSeconds` is 30, the Kubernetes maximum.
  Kyverno caches results per digest after that.
- **Fail closed.** `failurePolicy: Fail` means that if Kyverno or Sigstore
  can't be reached, matching pods are **denied**, not admitted. Pods that
  don't use this image are unaffected.
- **Scope.** The policies only match `ghcr.io/falconcrwd/slsademo`. Images from
  anywhere else pass through. To require that *everything* comes from a
  trusted, attested source, add a registry-allowlist policy.
- **Forks / renames.** The repo path, `repository_id`, and
  `repository_owner_id` are hard-coded. To get them for your own repo, run:
  `gh attestation download oci://ghcr.io/<you>/slsademo:latest --repo <you>/slsademo`
  then `jq '.dsseEnvelope.payload|@base64d|fromjson|.predicate.buildDefinition.internalParameters' sha256:*.jsonl`.
- **Private repos / GHCR packages.** Add `spec.credentials.secrets:
  [<dockerconfigjson secret in the kyverno namespace>]` so Kyverno can pull.
  Private-repo attestations are signed by GitHub's own Sigstore instance, not
  public-good. Supply its trust root with `attestors[].cosign.trustedRoot`
  (the output of `gh attestation trusted-root`) and drop the `ctlog` block.
