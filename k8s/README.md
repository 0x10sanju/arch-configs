# Kubernetes cluster setup (kubeadm + containerd + Calico)

Ubuntu/Debian nodes. Run the steps in order.

## 1. Every node (control plane AND workers)

```bash
sudo ./scripts/common/01-containerd-install.sh
sudo ./scripts/common/02-install-kubeadm.sh
```

Use the same Kubernetes version on every node (see the header of `02-install-kubeadm.sh`).

## 2. Control plane only

Initialize the cluster:

```bash
sudo kubeadm init
```

Set up kubectl for your user (run as your normal user, not root):

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

Install the network plugin (Calico). Replace the version with the one you want:

```bash
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.33.1/manifests/calico.yaml
```

Wait until the node shows `Ready` (can take a minute or two):

```bash
kubectl get nodes -w
```

## 3. Workers only

On the control plane, print a join command:

```bash
kubeadm token create --print-join-command
```

Run the printed command on each worker with `sudo`. Then, on the control plane:

```bash
kubectl get nodes
```

All nodes should show `Ready`.

## 4. Optional

If `kubectl top` fails with TLS errors on a dev cluster (metrics-server already installed):

```bash
./scripts/addons/metrics-server-insecure-tls.sh
```

Dev/lab clusters only. It disables kubelet certificate verification.

