#!/bin/bash
set -euo pipefail

K3S_VERSION_PIN="v1.33.4+k3s1" # renovate: datasource=github-releases depName=k3s-io/k3s versioning=regex:^v(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)\+k3s(?<build>\d+)$
K3S_VERSION="${K3S_VERSION:-${K3S_VERSION_PIN}}"

if [[ "${EUID}" -ne 0 ]]; then
	echo "must run as root" >&2
	exit 1
fi

if command -v k3s >/dev/null 2>&1; then
	echo "k3s already installed: $(k3s --version | head -n1)"
	exit 0
fi

curl -sfL https://get.k3s.io | \
	INSTALL_K3S_VERSION="${K3S_VERSION}" \
	INSTALL_K3S_EXEC="server --disable=traefik --write-kubeconfig-mode=0640" \
	sh -s -

until k3s kubectl get nodes 2>/dev/null | grep -q ' Ready '; do
	echo "waiting for node to become ready..."
	sleep 5
done

k3s kubectl get nodes

echo
echo "kubeconfig: /etc/rancher/k3s/k3s.yaml"
