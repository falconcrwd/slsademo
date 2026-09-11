# SLSA Build L3 Container Demo

A minimal, end-to-end demo that builds a container image on GitHub-hosted
runners and attaches **two signed attestations** to it:

1. **SLSA v1 Build Level 3 provenance** — who built it, from what source,
   with what workflow. Highest Build level SLSA v1 defines, and the highest
   achievable on the GitHub Free tier.
2. **An SPDX SBOM** — every package, Go module, and file inside the image,
   scanned by [Syft](https://github.com/anchore/syft).

Uses [`actions/attest@v4`][attest] (the current, supported provenance action).
The older `slsa-framework/slsa-github-generator` reusable workflow is
deprecated in favour of this path.

## What's in the box

| File | Purpose |
|------|---------|
| `main.go`, `go.mod` | Trivial HTTP "hello" service |
| `Dockerfile` | Multi-stage, distroless-static image |
| `.github/workflows/build.yml` | Build → push → attest provenance → SBOM → attest SBOM |
| `.github/workflows/verify.yml` | Consumer-side verification in CI via `cosign verify-attestation` (runs automatically after every successful build) |
| `verify.sh` | Consumer-side verification locally via `gh attestation verify` |
| `NOTES.md` | Deep-dive notes on the attestation bundle format and how in-toto / Sigstore / Fulcio / Rekor / Cosign fit together |

## Why this is SLSA Build L3 (and not higher)

SLSA v1.0 defines three Build levels; L3 is the top:

| Level | Requirement | How this demo satisfies it |
|-------|-------------|----------------------------|
| **L1** | Provenance exists, describes how the artifact was built | `actions/attest@v4` emits an in-toto v1.0 statement with a SLSA v1 build-provenance predicate |
| **L2** | Provenance is signed by the build platform; hosted build | Sigstore public-good keyless signing via GitHub's OIDC token; GitHub-hosted `ubuntu-latest` runner |
| **L3** | Isolated build; provenance is unforgeable by the tenant | OIDC identity is minted by the runner (not the workflow code) and binds the signature to this repo + workflow ref; verifiers pin those with `--repo`. GitHub documents this configuration as producing L3 provenance. |

There is no defined Build L4 in SLSA v1. Two adjacent tracks are out of scope:

- **Source track** — protected branches + reviewed source. Not shown here.
- **Hermetic / reproducible builds** — a stretch goal above L3.

## How it works

`.github/workflows/build.yml` has one job with four meaningful steps:

1. **Build and push** the image with Buildx. The `docker/build-push-action`
   `digest` output gives the immutable `sha256:…` for the pushed image; every
   subsequent step binds to that exact digest, not to a mutable tag.
2. **Attest build provenance** — `actions/attest@v4` in default mode (no
   `sbom-path` / `predicate-*` inputs) constructs a SLSA v1 build-provenance
   predicate about the image, signs it with a short-lived Sigstore Fulcio cert
   whose SAN is the OIDC identity of *this* workflow, uploads the signed
   bundle to GitHub's Attestations API, and pushes it to GHCR next to the
   image (`push-to-registry: true`).
3. **Generate SBOM** — `anchore/sbom-action` (a wrapper around
   [Syft](https://github.com/anchore/syft)) scans the pushed image pinned by
   digest and emits `sbom.spdx.json`, describing every package, Go module, and
   file inside the image.
4. **Attest SBOM** — a second `actions/attest@v4` call, this time in *SBOM
   mode* (triggered by `sbom-path`). Same subject digest as the provenance
   attestation, but the predicate is the SPDX document. Signed, uploaded,
   pushed to GHCR the same way.

Both attestations end up bound to the same image digest. `gh attestation
verify` filters by predicate type on each call (default is SLSA provenance),
so `verify.sh` runs it twice — once per predicate — to cover both.

Permissions the job needs (all standard, no PATs):

```yaml
contents: read
packages: write            # push image + attestation to GHCR
id-token: write            # mint OIDC token for Sigstore
attestations: write        # upload bundle to GH API
artifact-metadata: write   # create the artifact storage record
```

## Setup

1. Push this repo to GitHub as a **public** repo (attestations are also
   available for private repos, but that requires Enterprise Cloud; the free
   tier requires public).
2. In **Settings → Actions → General → Workflow permissions**, ensure
   *Read and write* is enabled so `packages: write` can push to GHCR.
3. Push to `main` (or open a PR). The workflow runs automatically.

That's it. No secrets to configure; `GITHUB_TOKEN` + OIDC handle everything.

## Verifying the provenance (consumer side)

There are two verifiers in this repo, doing the same job with different UI:

| Verifier | Tool | Where it runs | When to use |
|---|---|---|---|
| `verify.sh` | `gh attestation verify` | Locally on your machine | Ad-hoc: you're inspecting the image on your laptop |
| `.github/workflows/verify.yml` | `cosign verify-attestation` | GitHub Actions | Automatic: fires after every successful `build-and-attest` run; also manually via *Actions → verify-image → Run workflow* |

Both consume the exact same Sigstore bundles that `actions/attest@v4`
attached to the image, and both enforce the same properties: signature
chains to the Sigstore public-good root (image untampered), the Fulcio
cert's SAN identifies **this repo's `build.yml` workflow** (trusted
publisher), and the in-toto subject digest equals the image's real digest
(provenance bound to these exact bytes).

### Locally with `verify.sh`

Install the [GitHub CLI](https://cli.github.com/) — `gh attestation verify`
is built in. No extra tools.

```bash
./verify.sh <your-gh-user>/slsademo latest
```

A successful run prints two verification blocks — one for the SLSA
provenance predicate and one for the SPDX SBOM predicate — each ending in
`✓ Verification succeeded!`.

### In CI with the `verify-image` workflow

`.github/workflows/verify.yml` uses `sigstore/cosign-installer` +
`cosign verify-attestation` and runs automatically on every successful
build. It:

1. resolves `:latest` (or the tag you dispatch it with) to an immutable
   `@sha256:…` digest via `docker buildx imagetools inspect` — so a racing
   re-tag can't substitute a different image between resolve and verify,
2. runs `cosign verify-attestation --type slsaprovenance1` against that
   digest, pinning `--certificate-identity-regexp` to `build.yml` in this
   repo and `--certificate-oidc-issuer` to GitHub Actions,
3. does the same for the SPDX SBOM with `--type spdxjson`.

The workflow needs no secrets beyond the default `GITHUB_TOKEN` (used only
to pull from GHCR). To verify a tag other than `latest`, dispatch it from
the Actions tab and pass the tag as input.

`gh attestation verify` filters attestations by predicate type per call
(default is `https://slsa.dev/provenance/v1`), so `verify.sh` calls it once
per predicate. To confirm both attestations are present without verifying,
list them:

```bash
gh attestation download oci://ghcr.io/<user>/slsademo:latest --repo <user>/slsademo
# Writes to <image-digest>.jsonl in the current directory, e.g.
#   sha256:92c04c0…f6ac.jsonl

jq -r '.dsseEnvelope.payload | @base64d | fromjson | .predicateType' sha256:*.jsonl
# https://slsa.dev/provenance/v1
# https://spdx.dev/Document/v2.3
```

Under the hood, `gh attestation verify`:

- resolves the tag to an image digest via the registry,
- fetches the attestation from GHCR (or the GH Attestations API, whichever
  is available),
- verifies the Sigstore signature chains to the public-good root,
- checks that the certificate's OIDC identity is a workflow in `--repo`,
- checks that the in-toto `subject.digest` equals the image's real digest.

For a stricter check, pin the workflow ref explicitly:

```bash
gh attestation verify oci://ghcr.io/<user>/slsademo:latest \
  --repo <user>/slsademo \
  --signer-workflow <user>/slsademo/.github/workflows/build.yml
```

To eyeball the raw attestations without verifying:

```bash
gh attestation download oci://ghcr.io/<user>/slsademo:latest --repo <user>/slsademo
# Writes <image-digest>.jsonl (e.g. sha256:92c04c0…f6ac.jsonl) —
# one JSON line per attestation.

# Provenance predicate:
jq -r 'select(.dsseEnvelope.payloadType=="application/vnd.in-toto+json")
       | .dsseEnvelope.payload | @base64d | fromjson
       | select(.predicateType | startswith("https://slsa.dev/"))' sha256:*.jsonl

# SPDX SBOM predicate:
jq -r 'select(.dsseEnvelope.payloadType=="application/vnd.in-toto+json")
       | .dsseEnvelope.payload | @base64d | fromjson
       | select(.predicateType | startswith("https://spdx.dev/"))' sha256:*.jsonl
```

## Running the container locally

```bash
docker run --rm -p 8080:8080 ghcr.io/<your-gh-user>/slsademo:latest
curl localhost:8080
# hello from a SLSA Build L3 container
```

## References

- Using artifact attestations — <https://docs.github.com/en/actions/security-guides/using-artifact-attestations-to-establish-provenance-for-builds>
- `actions/attest` — <https://github.com/actions/attest>
- `anchore/sbom-action` (Syft) — <https://github.com/anchore/sbom-action>
- SPDX v2.3 spec — <https://spdx.github.io/spdx-spec/v2.3/>
- SLSA v1.0 spec — <https://slsa.dev/spec/v1.0/>
- Build L3 requirements — <https://slsa.dev/spec/v1.0/levels#build-l3>

[attest]: https://github.com/actions/attest
