# SLSA Build L3 Container Demo

A minimal, end-to-end demo that builds a container image on GitHub-hosted
runners and attaches **SLSA v1 Build Level 3** provenance to it — the highest
Build level SLSA v1 defines, and the highest achievable on the GitHub Free
tier.

Uses [`actions/attest@v4`][attest] (the current, supported provenance action).
The older `slsa-framework/slsa-github-generator` reusable workflow is
deprecated in favour of this path.

## What's in the box

| File | Purpose |
|------|---------|
| `main.go`, `go.mod` | Trivial HTTP "hello" service |
| `Dockerfile` | Multi-stage, distroless-static image |
| `.github/workflows/build.yml` | Build → push → attest, all in one job |
| `verify.sh` | Consumer-side verification via `gh attestation verify` |

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

`.github/workflows/build.yml` has one job:

1. Build the image with Buildx and push it to GHCR. The `docker/build-push-action` `digest` output gives the immutable `sha256:…` for the pushed image.
2. `actions/attest@v4` runs with **no `sbom-path`/`predicate-*` inputs**, which puts it in default *provenance mode*: it constructs a SLSA v1 build-provenance predicate about the built image, signs it with a short-lived Sigstore Fulcio cert whose SAN is the OIDC identity of *this* workflow, and:
   - uploads the signed bundle to GitHub's Attestations API (indexed on the repo — visible under **Actions → Attestations**), and
   - pushes it to GHCR next to the image (`push-to-registry: true`), so registry consumers can verify without hitting GitHub.

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

Install the [GitHub CLI](https://cli.github.com/) — `gh attestation verify`
is built in. No extra tools.

```bash
./verify.sh <your-gh-user>/slsademo latest
```

A successful run prints something like:

```
Loaded digest sha256:… for oci://ghcr.io/<user>/slsademo:latest
Loaded 1 attestation from GitHub API
✓ Verification succeeded!
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

To eyeball the raw attestation without verifying:

```bash
gh attestation download oci://ghcr.io/<user>/slsademo:latest --repo <user>/slsademo
cat attestation.jsonl | jq .
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
- SLSA v1.0 spec — <https://slsa.dev/spec/v1.0/>
- Build L3 requirements — <https://slsa.dev/spec/v1.0/levels#build-l3>

[attest]: https://github.com/actions/attest
