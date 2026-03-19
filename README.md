# debz — free edition

**Debian 13 (trixie) · ZFS on root · ZFSBootMenu · Live installer**

debz is a live bootable OS image that installs Debian 13 with ZFS on root as the default. Boot the ISO, open the browser-based installer, pick your target type, and you have a production-ready ZFS system in minutes — fully offline capable.

---

## What it does

- **Live ISO** boots to a GNOME desktop with a web-based installer at `https://<ip>:8080`
- **ZFS on root** — pool layout with boot environments, snapshots, and automatic APT snapshot hooks baked in
- **ZFSBootMenu** — UEFI bootloader with boot environment management
- **Darksite** — full offline APT mirror baked into the ISO (~2500 packages, no internet required to install)
- **7 install targets** — Desktop, Server, KVM Host, Storage, Monitoring, Proxmox, VDI
- **Post-install snapshot** — `rpool@install-<timestamp>` taken automatically after every install for instant rollback

## Install targets

| Target | What gets installed |
|---|---|
| **Desktop** | GNOME, GDM, NetworkManager, SSH |
| **Server** | Base system, SSH, systemd-resolved |
| **KVM Host** | QEMU/KVM, libvirt, containerd, Firecracker microVM runtime |
| **Storage** | NFS, iSCSI (tgt), Samba, ZFS datasets |
| **Monitoring** | Prometheus, Grafana, Alertmanager, node-exporter |
| **Proxmox** | Base system + Proxmox VE repo configured for firstboot install |
| **VDI** | Wayland, FFmpeg, pipewire, nginx |

---

## Building

**Host requirements:** `docker` (or `podman`) and `git`. That's it. live-build, debootstrap, ZFS tools, and all build dependencies run inside the container — nothing else needs to be installed on your machine.

```bash
# Clone
git clone https://github.com/debz-ca/debz.git
cd debz

# First time: build the builder container image (~5 min)
./deploy.sh builder-image

# Build the ISO (~20-40 min depending on network, darksite downloads ~2500 packages)
./deploy.sh build-live

# ISO lands at:
./deploy.sh latest-iso

# Or full clean rebuild in one step
./deploy.sh rebuild
```

Works on any Linux host with Docker or Podman. Tested on Debian, Ubuntu, Fedora.

### Build commands

```bash
./deploy.sh build-live      # Build ISO (requires builder image)
./deploy.sh builder-image   # Build the Docker builder container
./deploy.sh rebuild         # clean + builder-image + build-live
./deploy.sh clean           # Remove local build state
./deploy.sh deploy          # Upload ISO to Proxmox + create test VM
./deploy.sh latest-iso      # Print newest ISO path
```

---

## ZFS pool layout

```
bpool  (grub2 compatibility)
└── BOOT/<hostname>          ← /boot

rpool
├── ROOT/<hostname>          ← /  (boot environment, canmount=noauto)
├── home                     ← /home
├── root                     ← /root
├── srv                      ← /srv
├── opt                      ← /opt
├── tmp                      ← /tmp  (sync=disabled)
├── usr/local                ← /usr/local
└── var/
    ├── cache                ← /var/cache
    ├── lib                  ← /var/lib
    ├── log                  ← /var/log
    ├── spool                ← /var/spool
    └── tmp                  ← /var/tmp
```

Pool properties: `ashift=12`, `compression=lz4`, `autotrim=on`, `xattr=sa`, `acltype=posixacl`

---

## Architecture

```
deploy.sh
  └── builder/container-build.sh   (privileged Docker container)
        └── builder/build-iso.sh   (lb config + lb build)
              └── live-build/config/
                    └── live-build/output/  (ISO — gitignored)
```

---

## Web UI

The installer runs at `https://<ip>:8080` on the live system.

- Dashboard — hostname, uptime, CPU, memory, NIC status, ZFS pool health
- Install — target type selector, disk wipe, full installer with progress log
- ZFS — pool status, snapshot management, boot environments

Backend: Python asyncio + websockets, single port (HTTP + WebSocket).

---

## License

debz is released under the **BSD 3-Clause License**. See [LICENSE](LICENSE).

Third-party components (Linux kernel, OpenZFS, GNOME, Docker, Kubernetes, etc.) retain their own licenses. Source for all GPL/AGPL components is available from their respective upstream projects — debz installs them unmodified from official APT repositories.

---

## Pro edition

The free edition installs the foundation. **debz Pro** adds 1-touch cluster deployment, golden image management, node orchestration, and automated networking. See [debz.ca](https://debz.ca) for details.
