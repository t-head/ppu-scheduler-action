#!/usr/bin/env bash
set -euo pipefail

# ARC Controller v0.14.2
helm install arc \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller \
  --namespace arc-systems \
  --version 0.14.2
