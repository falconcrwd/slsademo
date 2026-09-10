#!/usr/bin/env bash
# Verify the SLSA build-provenance attestation attached to the pushed image.
#
# Uses the GitHub CLI's attestation command, which is the supported way to
# verify attestations produced by actions/attest@v4. No extra tools needed —
# `gh` ships with `gh attestation verify` built in.
#
# Usage:
#   ./verify.sh <OWNER>/<REPO>            # verifies :latest
#   ./verify.sh <OWNER>/<REPO> <TAG>      # verifies a specific tag
#
# What it checks:
#   - the attestation's Sigstore signature chains to the public-good root,
#   - the signing certificate's OIDC identity resolves to a workflow in
#     <OWNER>/<REPO> (enforced by --repo),
#   - the in-toto subject digest equals the image's real digest.
set -euo pipefail

REPO="${1:?usage: verify.sh <owner>/<repo> [tag]}"
TAG="${2:-latest}"
IMAGE="oci://ghcr.io/${REPO}:${TAG}"

gh attestation verify "${IMAGE}" --repo "${REPO}"
