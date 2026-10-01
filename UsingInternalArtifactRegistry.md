# Internal artifact registries as a dependency chokepoint

## The core pattern

```
┌─────────────┐         ┌──────────────────────┐         ┌─────────────┐
│  Public     │  pull   │  Internal artifact   │  pull   │  CI runner  │
│  registry   │◄────────┤  registry (proxy)    │◄────────┤  / dev      │
│  (npm, etc) │         │                      │         │  laptop     │
└─────────────┘         └──────────────────────┘         └─────────────┘
                          ▲
                          │ policy: quarantine, scan,
                          │ allowlist, deny-by-default
```

Your workflows and developers never talk to `registry.npmjs.org` / `proxy.golang.org` / `docker.io` / `pypi.org` directly. They talk to `npm.corp.internal` / `go.corp.internal` / `docker.corp.internal`. The internal registry is the only thing with egress to the public internet for package fetches.

Concretely, `.npmrc` / `go env GOPROXY` / Docker's `registries.conf` / `pip.conf` point at your internal host. That's the only change most builds need.

## Two flavours: pull-through cache vs. curated mirror

There are two architectures with different security postures. Most orgs run both, for different classes of dependency.

### Flavour A: pull-through cache (also called "remote repository" or "virtual repository")

The internal registry acts lazily. When someone requests `left-pad@1.3.0`:

1. Check local cache. Hit → serve.
2. Miss → fetch from `registry.npmjs.org`, apply policies (see below), store locally, serve.

The public registry is still the source of truth; you're caching + gating. This is the common default because it's low-friction: developers can request anything, and it just works after a first-fetch delay.

**Where the security comes from:** the *policies* applied at fetch time. Without policies, this is just a cache and gives you nothing new.

### Flavour B: curated / vetted mirror

Nothing is available until someone (or something) explicitly approves it into the internal registry. Requests for un-vetted packages fail.

Higher friction, higher assurance. Typical for regulated environments (finance, defence, healthcare) or for a small set of "gold" images and base layers that must be trusted absolutely.

Most orgs use a hybrid: **curated for base images and critical infrastructure** (the ten-ish container base images your whole fleet is built from), **pull-through with quarantine for application-layer libs** (thousands of transitive npm/pip/go deps).

## What the internal registry actually gives you that a direct pull doesn't

If the internal registry is just a caching proxy with no policies, you've bought only availability (survives npm outage) and bandwidth savings. The security wins come from **what you do at the choke point**:

### 1. Quarantine / minimum-release-age

Refuse to serve any version of any package published in the last N hours (typically 24-72h). Rationale: most malicious packages are yanked from public registries within a day of publication by community reporting. A 48h quarantine window would have caught `event-stream@3.3.6`, `ua-parser-js`, most of the `chalk`/`debug` typosquats, and the recent `tj-actions/changed-files` blast.

Trade-off: you can't consume same-day patches. Usually acceptable; if not, exception-list critical security-only channels.

### 2. Vulnerability + malware scanning at ingress

Every new artifact entering the registry gets scanned (Grype/Trivy/Snyk/Socket/Phylum) before it's available to internal consumers. Failed scan → doesn't enter the shelf. This is the same scanning you'd do in CI, but done *once, centrally*, before any build has a chance to touch the artifact.

### 3. Allowlist / denylist policies

- **Allowlist:** only these package names, or only from these publishers, or only these licences. Common in monorepos where the dependency list is deliberately curated.
- **Denylist:** known-bad versions, known-malicious names, known-abandoned packages. Fed by threat intel (OSV `MAL-` advisories, GHSA, internal IR).

### 4. Immutability and retention

Public registries can and do delete versions (`npm unpublish`, the infamous `left-pad` incident). An internal registry retains what it has served forever — your builds remain reproducible even if upstream disappears.

Corollary: your build's `sha256:…` reference to a base image *always* resolves, even if the publisher deleted the tag.

### 5. Audit trail

Every pull is logged with the requesting identity (CI job, developer, service account). When the next `xz-utils` drops, you can answer *"which builds pulled the compromised version, and when?"* in one SQL query, rather than by grep-across-all-CI-logs.

### 6. Consuming and re-signing attestations

The internal registry can:
- **Verify** upstream Sigstore/npm provenance signatures at ingress, refuse artifacts without valid provenance from an allowlisted publisher identity.
- **Re-attest** the artifact with an internal signing key, so downstream consumers verify against *your* trust root, not Sigstore's public-good root. This matters in air-gapped or highly regulated environments where "the public internet is the trust root" is not acceptable.

### 7. Egress control becomes tractable

The single biggest operational win. Once all dependency pulls go through one host, you can:
- Firewall CI runners so they can reach `*.corp.internal` and nothing else on the internet.
- Any outbound to an unexpected destination during a build is now unambiguously suspicious (malicious `postinstall` phoning home, exfiltration attempt).
- Without the internal registry, "CI needs internet" means "CI can reach anything," and detecting exfil is much harder.

## What products actually do this

| Product | Notes |
|---|---|
| **JFrog Artifactory** | The category leader. Handles every ecosystem (npm, PyPI, Maven, Go, Docker/OCI, Helm, generic). Policies, scanning (Xray), curation, HA. Commercial. |
| **Sonatype Nexus Repository** | Similar scope. OSS edition is genuinely usable for smaller orgs. IQ Server adds policy/scanning. |
| **AWS CodeArtifact** | Managed, integrates with IAM. Handles npm/PyPI/Maven/NuGet/Swift/generic; separate ECR for containers. |
| **GCP Artifact Registry** | Managed, integrates with GCP IAM + Binary Authorization. All formats including containers. |
| **Azure Artifacts** | Managed on Azure DevOps. Multi-ecosystem. |
| **GitHub Packages** | Bundled with GitHub. Good enough for org-internal packages + basic proxying, thin on policy/scanning versus the above. |
| **Harbor** | OSS, container-focused. Vulnerability scanning built in, Cosign policy integration, replication. Common self-hosted choice for Kubernetes shops. |
| **Cloudsmith, Bytesafe, Gemfury** | Newer managed offerings, polyglot, tend to lead on developer experience. |

For a hobby project like `slsademo`: overkill. For anything running production workloads with more than a handful of engineers: essentially table stakes, and the reason many recent supply-chain compromises didn't hit large orgs.

## Configuring the workflows to use it

The wiring is mostly one-line per ecosystem. Rough shape:

**npm** — `.npmrc` in the repo:
```
registry=https://npm.corp.internal/
//npm.corp.internal/:_authToken=${NPM_TOKEN}
```

**Go** — env var in the workflow:
```yaml
env:
  GOPROXY: https://go.corp.internal,direct
  GOSUMDB: sum.corp.internal
```
(Or `GOPROXY: https://go.corp.internal` without `direct` to *require* the proxy — no fallback to public.)

**pip** — `pip.conf` or CLI flag:
```
[global]
index-url = https://pypi.corp.internal/simple/
```

**Docker/OCI** — reference base images by internal hostname:
```dockerfile
FROM docker.corp.internal/distroless/static:nonroot
```
(Or use registry mirrors config on the builder to transparently rewrite `docker.io/...` → `docker.corp.internal/dockerhub/...`.)

Then, at the network layer: block egress from CI runners to the public registries. Now attempts to bypass the internal registry *fail*, which is what makes the control actually enforceable rather than advisory.

## The one gotcha to be aware of

**Dependency confusion.** If your internal registry serves both mirrored public packages *and* your org's own private packages, and you configure a client to check both, an attacker who publishes a package named the same as one of your private packages on the *public* registry can trick your builds into pulling the malicious public one. This is what hit Apple, Microsoft, and Uber in 2021.

Mitigations, all supported by the products above: scoped packages (`@yourorg/foo`), explicit routing rules ("this name pattern → private only, never fall through to public"), or registering your private names as reserved on the public registry.

---

So yes: mirror + point workflows at the internal host. But the mirror is the *plumbing*; the security comes from the **policies** and **egress control** it enables. Without those, it's a bandwidth optimisation.
