# Nested containers in a non-privileged Kata microVM

Run a container **inside a VM-isolated microVM**, with **`privileged: false`**, reproduced on an
**Apple Silicon Mac** (M3+) using nested virtualization. `make up && make test` →

```
=== podman run hello-world ===
Hello from Docker!
RUN_OK
=== podman build + run ===
BUILD_OK proof=[BUILT_INSIDE_MICROVM]
```

A container — run *and* built — inside a non-privileged [Kata Containers](https://katacontainers.io/) microVM,
on a laptop. No `privileged: true`, so no host devices leak into the guest — the VM stays the only
trust boundary.

## Why

If you run untrusted code (an AI agent's `npm install` / test suite / `docker build`, CI for a
third-party PR, a sandbox), a shared-kernel container is not a boundary. A **microVM per run** is.
Kata gives you that. But the workload often needs to **run containers itself** (Testcontainers,
`docker build`, a DB container) — *nested* containers inside the microVM. The usual way,
`privileged: true`, hot-plugs **host devices** into the guest, which is exactly the isolation hole
the VM was supposed to close. So: nested containers, in a microVM, non-privileged. This repo is the
worked recipe.

> **Most of this is not about Macs.** Only the host-virt layer (gotchas 1–2) is Apple-specific.
> Gotchas 3–12 — the privilege model, cgroup2 delegation, OCI runtime, storage driver, networking —
> are identical on any x86 Kata node, in the cloud or in CI. The Mac is just the cheapest place to
> reproduce them.

## Requirements

- Apple Silicon **M3 or newer**, **macOS 15+** (nested virtualization). M1/M2 cannot do this.
- [Lima](https://lima-vm.io/) (`brew install lima`).

## Run

```sh
make up       # create the Lima VM (+ raw devmapper disk), install Kata + Cloud Hypervisor + k3s
make test     # launch the non-privileged box and run a nested container inside the microVM
make down     # tear it all down
```

`make up` takes ~10 minutes (image + a ~700 MB Kata download). `make test` prints the pod log; look
for `RUN_OK`.

## What's in the box

| File | What |
| --- | --- |
| `lima/kata-poc.yaml` | the Lima VM: `vz` + `nestedVirtualization` + a raw 50G disk for devmapper |
| `setup/provision.sh` | devmapper thin-pool on the real disk, Kata + Cloud Hypervisor, k3s wired to them |
| `box.yaml` | the non-privileged pod (caps, not `privileged`) + the in-box bootstrap + the nested-container test |

## The stack that works

| Layer | Choice | Why |
| --- | --- | --- |
| Host virt | Lima `vz` + `nestedVirtualization` | nested-virt → `/dev/kvm` in the guest (M3+/macOS 15+) |
| Hypervisor | Kata + **Cloud Hypervisor** | QEMU hangs on nested virt |
| Snapshotter | **devmapper on a real block device** | loopback / overlayfs both break |
| Pod privilege | **non-privileged + caps** | `privileged: true` hot-plugs host devices into the VM |
| OCI runtime | **crun** | runc fails cgroup2 init |
| Engine | **podman**, `--cgroup-manager=cgroupfs --storage-driver=vfs` | no sd-bus, no `/dev/fuse` |

## The 12 errors behind it

Each fix only revealed the next wall. In order:

1. **QEMU hangs on nested virt** (`exiting QMP loop, command cancelled`) → **Cloud Hypervisor** / Firecracker.
2. **loopback devmapper + clh** (`Failed to get Write lock for disk image: already locked`) → a **real block device**.
3. **`privileged: true` → host-device passthrough** (`/dev/loop0`, `/dev/dm-0`, `Failed to parse disk image format`). `privileged_without_host_devices` did not suppress it on clh → use **caps, not privileged**.
4. **overlayfs snapshotter mis-detects the rootfs as a block device** (the [CVE-2026-24054](https://github.com/kata-containers/kata-containers/security/advisories/GHSA-5fc8-gg7w-3g5c) class; worst with `VOLUME` images like `docker:dind`) → **devmapper**.
5. **cgroup2 read-only** (`mkdir /sys/fs/cgroup/...: read-only file system`) → `mount -o remount,rw` (needs `SYS_ADMIN`).
6. **cgroup2 "no internal process" rule** (`subtree_control` write rejected) → evacuate processes to `/init` first, then delegate.
7. **`io` controller not delegated** → add `resources.limits` so k8s/Kata delegates it.
8. **runc** (`can't get final child's PID from pipe: EOF`) → **crun**.
9. **crun wants systemd's sd-bus** (`cannot open sd-bus`) → `--cgroup-manager=cgroupfs`.
10. **`oom_score_adj: Permission denied`** → add **`SYS_RESOURCE`**.
11. **fuse-overlayfs / `/dev/fuse` not found** → `--storage-driver=vfs`.
12. **netavark `set sysctl ... read-only`** → `--network=none` (the engine pulls images on the box's own network; the container itself often needs none).

## Production notes

- Gotchas 3–12 are not Mac-specific — they recur on x86 prod nodes; the Mac VM reproduces them
  faithfully. Only the host-virt layer (1–2) differs (bare metal or a nested-virt-capable cloud node
  replaces the Lima VM).
- `--storage-driver=vfs` is for the proof, not production speed; real workers want overlay2 on the
  devmapper-backed rootfs.
- A **systemd-init box image** is the cleaner long-term shape — systemd owns the cgroup2 delegation
  the in-box bootstrap does by hand (boot it after remounting `/sys/fs/cgroup` rw before `exec /sbin/init`).

## License

MIT. The orchestrated components (Kata, Lima, k3s, containerd, crun, podman) are their own upstream
licenses.
