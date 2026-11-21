#!/usr/bin/env bash
# Prepare a node for Kubernetes: swap off, kernel modules, sysctls, containerd.
# Run on EVERY node (control plane and workers), before 02-install-kubeadm.sh.
# Idempotent: re-running changes nothing (and restarts nothing) if the node is already configured.
set -euo pipefail

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

STATE_DIR=/var/lib/k8s-node-setup
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

# ---------- Swap ----------
log "Disabling swap"
swapoff -a
[ -f /etc/fstab.bak ] || cp /etc/fstab /etc/fstab.bak
# Comment out any non-comment line whose 3rd column is "swap"
awk '{
  line = $0
  sub(/^[[:space:]]*/, "", line)
  if (line ~ /^#/) { print $0; next }
  if ($3 == "swap") { print "#" $0; next }
  print $0
}' /etc/fstab > "$WORK/fstab"
if ! cmp -s "$WORK/fstab" /etc/fstab; then
  install -m 0644 "$WORK/fstab" /etc/fstab
fi

# ---------- Kernel modules ----------
log "Loading kernel modules"
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

# ---------- Sysctl ----------
log "Applying sysctl settings"
cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system > /dev/null

# ---------- containerd ----------
log "Installing containerd"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y containerd

VERSION=$(containerd --version | awk '{for (i=1;i<=NF;i++) if ($i ~ /^v?[0-9]+\.[0-9]+/) { sub(/^v/,"",$i); print $i; exit }}')
MAJOR=${VERSION%%.*}
log "Detected containerd $VERSION"

case "$MAJOR" in
  1) PATTERN='io.containerd.grpc.v1.cri.*runtimes.runc.options' ;;
  2) PATTERN='io.containerd.cri.v1.runtime.*runtimes.runc.options' ;;
  *) die "Unsupported containerd major version: '$MAJOR'" ;;
esac

log "Configuring containerd (systemd cgroups)"
mkdir -p /etc/containerd "$STATE_DIR"
[ ! -f /etc/containerd/config.toml ] || [ -f /etc/containerd/config.toml.bak ] || \
  cp /etc/containerd/config.toml /etc/containerd/config.toml.bak

# Only touch SystemdCgroup inside the runc options section; fail unless exactly one line changed
containerd config default | awk -v pattern="$PATTERN" '
/^[[:space:]]*\[/ { in_target = ($0 ~ pattern) }
in_target && /^[[:space:]]*SystemdCgroup[[:space:]]*=/ { sub(/=.*/, "= true"); changed++ }
{ print }
END {
  if (changed != 1) {
    print "ERROR: could not uniquely set SystemdCgroup" > "/dev/stderr"
    exit 1
  }
}' > "$WORK/config.toml"

if ! cmp -s "$WORK/config.toml" /etc/containerd/config.toml; then
  install -m 0644 "$WORK/config.toml" /etc/containerd/config.toml
fi

# Restart only if the running daemon may not be using this config:
# the config hash differs from the last one we applied, or containerd isn't running.
# The hash is saved only AFTER a successful restart, so an interrupted run is retried.
systemctl enable containerd
want=$(sha256sum /etc/containerd/config.toml | cut -d' ' -f1)
have=$(cat "$STATE_DIR/containerd-config.sha256" 2>/dev/null || true)
if [ "$want" != "$have" ] || ! systemctl is-active --quiet containerd; then
  systemctl restart containerd
  echo "$want" > "$STATE_DIR/containerd-config.sha256"
fi

# ---------- Verify ----------
log "Verifying"
fail=0
check() { # check "description" command...
  local desc=$1; shift
  if "$@" >/dev/null 2>&1; then echo "  [ok]   $desc"; else echo "  [FAIL] $desc"; fail=1; fi
}
check "swap is off"               test -z "$(swapon --show)"
check "overlay present"           test -d /sys/module/overlay
check "br_netfilter present"      test -d /sys/module/br_netfilter
check "ip_forward = 1"            test "$(sysctl -n net.ipv4.ip_forward)" = 1
check "bridge-nf-call-iptables=1" test "$(sysctl -n net.bridge.bridge-nf-call-iptables)" = 1
check "SystemdCgroup = true"      grep -q 'SystemdCgroup = true' /etc/containerd/config.toml
check "containerd is active"      systemctl is-active --quiet containerd

[ "$fail" -eq 0 ] || die "One or more checks failed, see above"
log "Done: $(containerd --version)"

