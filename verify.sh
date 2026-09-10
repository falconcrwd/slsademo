#!/usr/bin/env bash
# Verify both signed attestations attached to the pushed image:
#   1. SLSA v1 build provenance   (predicate: https://slsa.dev/provenance/v1)
#   2. SPDX SBOM                  (predicate: https://spdx.dev/Document/v2.3)
#
# `gh attestation verify` filters by predicate type on each invocation
# (default is SLSA provenance), so verifying both attestations requires two
# calls with different --predicate-type values.
#
# Usage:
#   ./verify.sh <OWNER>/<REPO>            # verifies :latest
#   ./verify.sh <OWNER>/<REPO> <TAG>      # verifies a specific tag
#
# What each check enforces:
#   - Sigstore signature chains to the public-good root,
#   - the signing certificate's OIDC identity resolves to a workflow in
#     <OWNER>/<REPO> (enforced by --repo),
#   - the in-toto subject digest equals the image's real digest,
#   - the predicate is the one we expect for that attestation kind.
set -euo pipefail

REPO="${1:?usage: verify.sh <owner>/<repo> [tag]}"
TAG="${2:-latest}"
IMAGE="oci://ghcr.io/${REPO}:${TAG}"

echo "──▶ Verifying SLSA build provenance"
gh attestation verify "${IMAGE}" \
  --repo "${REPO}" \
  --predicate-type https://slsa.dev/provenance/v1

echo
echo "──▶ Verifying SPDX SBOM"
gh attestation verify "${IMAGE}" \
  --repo "${REPO}" \
  --predicate-type https://spdx.dev/Document/v2.3
