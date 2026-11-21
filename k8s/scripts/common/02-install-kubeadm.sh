#!/usr/bin/env bash
# Install kubeadm, kubelet and kubectl from the official Kubernetes apt repo.
# Run on EVERY node (control plane and workers), after 01-containerd-install.sh.
# Idempotent: re-running changes nothing if the node already has this version.
#
# Default: latest stable minor release. To pin (recommended; use the SAME
# value on every node):   sudo K8S_VERSION=v1.34 ./02-install-kubeadm.sh
set -euo pipefail

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ---------- Preflight ----------
[ "$(id -u)" -eq 0 ] || die "Run as root: sudo $0"
# shellcheck source=/dev/null
. /etc/os-release
case "${ID:-}" in
  ubuntu|debian) ;;
  *) die "Unsupported OS '${ID:-unknown}' (expects Ubuntu/Debian)" ;;
esac

systemctl is-active --quiet containerd 2>/dev/null \
  || warn "containerd is not running. Run 01-containerd-install.sh first."

# ---------- Dependencies ----------
log "Installing dependencies"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y apt-transport-https ca-certificates curl gpg

# ---------- Resolve Kubernetes version ----------
if [ -z "${K8S_VERSION:-}" ]; then
  log "Looking up latest stable Kubernetes version"
  K8S_VERSION=$(curl -fsSL --retry 3 https://dl.k8s.io/release/stable.txt \
    | grep -oE '^v[0-9]+\.[0-9]+' || true)
fi
K8S_VERSION=v${K8S_VERSION#v}   # accept "1.34" or "v1.34"
[[ "$K8S_VERSION" =~ ^v[0-9]+\.[0-9]+$ ]] \
  || die "Bad Kubernetes version '$K8S_VERSION' (expected like v1.34)"
log "Using Kubernetes $K8S_VERSION"

# Refuse to switch minor versions on an installed node: packages are held,
# and minor upgrades must follow the official 'kubeadm upgrade' procedure.
if command -v kubeadm >/dev/null 2>&1; then
  installed=$(kubeadm version -o short 2>/dev/null | grep -oE '^v[0-9]+\.[0-9]+' || true)
  if [ "$installed" != "$K8S_VERSION" ]; then
    die "kubeadm '${installed:-unknown}' is already installed but '$K8S_VERSION' was requested. Upgrade with the official kubeadm upgrade procedure instead."
  fi
fi

# ---------- Apt repo ----------
log "Configuring Kubernetes apt repository"
curl -fsSL --retry 3 \
  "https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key" > "$WORK/release.key"
gpg --dearmor --yes -o "$WORK/kubernetes-apt-keyring.gpg" "$WORK/release.key"
mkdir -p -m 0755 /etc/apt/keyrings
install -m 0644 "$WORK/kubernetes-apt-keyring.gpg" /etc/apt/keyrings/kubernetes-apt-keyring.gpg

cat > /etc/apt/sources.list.d/kubernetes.list <<EOF
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ /
EOF

# ---------- Install ----------
log "Installing kubelet, kubeadm, kubectl"
apt-get update -y
apt-get install -y kubelet kubeadm kubectl

# Hold versions so a routine apt upgrade can't move the node to a new version
apt-mark hold kubelet kubeadm kubectl > /dev/null

# kubelet restarts in a loop until 'kubeadm init' / 'kubeadm join' runs. This is expected.
systemctl enable kubelet

# ---------- Verify ----------
log "Verifying"
fail=0
check() { # check "description" command...
  local desc=$1; shift
  if "$@" >/dev/null 2>&1; then echo "  [ok]   $desc"; else echo "  [FAIL] $desc"; fail=1; fi
}
check "kubeadm installed"  command -v kubeadm
check "kubelet installed"  command -v kubelet
check "kubectl installed"  command -v kubectl
check "packages on hold"   test "$(apt-mark showhold | grep -cE '^(kubelet|kubeadm|kubectl)$')" -eq 3
check "kubelet enabled"    systemctl is-enabled --quiet kubelet

[ "$fail" -eq 0 ] || die "One or more checks failed, see above"
log "Done: $(kubeadm version -o short)"
echo "Use the same version on every node: K8S_VERSION=$K8S_VERSION"

