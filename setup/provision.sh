#!/usr/bin/env bash
# Provision the guest: a real-disk devmapper thin-pool, Kata + Cloud Hypervisor,
# k3s wired to use them. Run inside the Lima VM (the Makefile does this for you).
set -euo pipefail

KATA_VERSION="${KATA_VERSION:-3.31.0}"

echo "== 1. find the raw 50G data disk and build a devmapper thin-pool =="
RAW=$(lsblk -dn -o NAME,SIZE,TYPE | awk '$3=="disk" && $2 ~ /50G/ {print $1; exit}')
[ -n "$RAW" ] || { echo "no 50G raw disk found"; lsblk; exit 1; }
echo "raw disk = /dev/$RAW"
if ! sudo dmsetup status devpool >/dev/null 2>&1; then
  sudo parted -s "/dev/$RAW" mklabel gpt mkpart meta 1MiB 4GiB mkpart data 4GiB 100%
  sudo partprobe "/dev/$RAW"; sleep 1
  sudo dd if=/dev/zero of="/dev/${RAW}1" bs=1M count=10 2>/dev/null
  SECT=$(( $(sudo blockdev --getsize64 "/dev/${RAW}2") / 512 ))
  sudo dmsetup create devpool --table "0 $SECT thin-pool /dev/${RAW}1 /dev/${RAW}2 128 32768 1 skip_block_zeroing"
fi
sudo dmsetup status devpool

echo "== 2. install Kata Containers ${KATA_VERSION} (static) =="
sudo apt-get update -qq
sudo apt-get install -y -qq zstd curl >/dev/null
if [ ! -x /opt/kata/bin/kata-runtime ]; then
  curl -sSL -o /tmp/kata.tar.zst \
    "https://github.com/kata-containers/kata-containers/releases/download/${KATA_VERSION}/kata-static-${KATA_VERSION}-arm64.tar.zst"
  sudo tar --use-compress-program=unzstd -xf /tmp/kata.tar.zst -C /
fi
sudo ln -sf /opt/kata/bin/containerd-shim-kata-v2 /usr/local/bin/
sudo /opt/kata/bin/kata-runtime check || true   # informational

echo "== 3. install k3s and wire the kata-clh runtime onto the devmapper snapshotter =="
if ! command -v k3s >/dev/null 2>&1; then
  curl -sfL https://get.k3s.io | sudo sh -s - --write-kubeconfig-mode 644 >/dev/null
fi
sudo mkdir -p /var/lib/rancher/k3s/agent/etc/containerd
sudo tee /var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl >/dev/null <<'TMPL'
{{ template "base" . }}

[plugins."io.containerd.snapshotter.v1.devmapper"]
  pool_name = "devpool"
  root_path = "/var/lib/containerd/io.containerd.snapshotter.v1.devmapper"
  base_image_size = "12GB"

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata-clh]
  runtime_type = "io.containerd.kata.v2"
  snapshotter = "devmapper"
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata-clh.options]
    ConfigPath = "/opt/kata/share/defaults/kata-containers/configuration-clh.toml"
TMPL
sudo systemctl restart k3s
sleep 22
sudo k3s kubectl wait --for=condition=Ready node --all --timeout=120s
sudo k3s kubectl apply -f - <<'YAML'
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: kata-clh
handler: kata-clh
YAML

echo "== provision complete =="
