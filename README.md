# debz — free edition

**Debian 13 (trixie) · ZFS on root · ZFSBootMenu · Live installer**

debz is a live bootable Debian 13 ISO that installs a production-ready ZFS-on-root system in minutes — fully offline capable. Boot the ISO, open Firefox, navigate to `https://localhost:8080`, pick your target type, and go.

---

## What you get

- **GNOME live desktop** — boots straight to a desktop with Firefox pre-installed. Open `https://localhost:8080` to reach the installer.
- **Browser-based installer** — dashboard, disk selector, install target picker, live progress log, ZFS snapshot management
- **ZFS on root** — full dataset layout with boot environments, automatic APT snapshot hooks, and scheduled sanoid snapshots baked in
- **ZFSBootMenu** — UEFI bootloader with boot environment management built in
- **Darksite APT mirror** — ~2500 packages baked into the ISO. No internet required to install.
- **ZFS encryption** — optional AES-256-GCM full-disk encryption with passphrase unlock via ZFSBootMenu
- **Post-install snapshot** — `rpool@install-<timestamp>` taken automatically after every install for instant rollback
- **Sanoid scheduled snapshots** — daily, weekly, monthly, yearly retention on all datasets from first boot

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

## Using the installer

1. Boot the ISO (UEFI, bare metal or VM)
2. GNOME desktop loads automatically — open **Firefox**
3. Navigate to **`https://localhost:8080`** (accept the self-signed cert)
4. Fill in disk, hostname, username, target type, and click **Install**
5. Watch the live log — system powers off when complete
6. Boot the installed disk — ZFSBootMenu loads, then your system

The installer also works headlessly over the network — navigate to `https://<ip>:8080` from any machine on the same network.

---

## Building

**Requirements:** `docker` (or `podman`) and `git`. Everything else runs inside the container.

**Requirements:** `docker` and `git`. Everything else runs inside the container.

```bash
git clone https://github.com/debz-ca/debz-free.git
cd debz-free

# Build the builder container (~5 min, first time only)
./deploy.sh builder-image

# Build the ISO (~20-40 min)
./deploy.sh build

# Find the ISO
./deploy.sh latest-iso

# Burn to USB
USB_DEVICE=/dev/sdb ./deploy.sh burn
```

Works on any Linux host with Docker. Tested on Debian, Ubuntu, Fedora.

### Build commands

```bash
./deploy.sh builder-image   # Build the Docker builder container (do this first)
./deploy.sh build           # Build the ISO
./deploy.sh latest-iso      # Print path to the newest ISO
./deploy.sh burn            # Write ISO to USB  (USB_DEVICE=/dev/sdX)
./deploy.sh clean           # Remove build artifacts
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

Pool properties: `ashift=12`, `compression=lz4`, `autotrim=on`, `xattr=sa`, `acltype=posixacl`, `dnodesize=auto`, `normalization=formD`

---

## What's baked into the installed system

debz isn't just a Debian installer — every installed system gets a set of ZFS quality-of-life tools configured and ready from first boot.

### Automatic snapshots

**APT hooks** — a snapshot is taken automatically before and after every `apt install`, `apt upgrade`, or `apt remove`. Bad package update? Roll back in seconds.

```bash
# See all snapshots
zfs list -t snapshot -r rpool

# Roll back to before a package install
zfs rollback rpool/ROOT/<hostname>@apt-pre-20260101-120000
```

**Sanoid scheduled snapshots** — runs as a systemd timer, no config needed:

| Cadence | Kept | Covers |
|---------|------|--------|
| Daily   | 7    | 1 week |
| Weekly  | 12   | 3 months |
| Monthly | 12   | 1 year |
| Yearly  | 1    | long-term anchor |

Applied to: `/` (root), `/home`, `/var/lib`, `/srv`, `/root`

**Post-install snapshot** — immediately after install completes, before first boot:
```
rpool@install-20260101T120000Z   ← instant factory reset point
bpool@install-20260101T120000Z
```

### Snapshot management tools

```bash
snapshot-create.sh manual              # take a manual snapshot of root
snapshot-create.sh manual rpool/home   # snapshot a specific dataset
snapshot-policy.sh                     # report — counts vs limits for all groups
snapshot-prune.sh rpool/ROOT/<h> apt-pre 10  # prune a specific group manually
```

### Boot environment management

ZFSBootMenu is the bootloader. At boot, hold Space to access the boot environment menu — roll back to any previous boot environment without booting into the OS at all.

From a running system:

```bash
debz-be list                           # list all boot environments and snapshots
debz-be create pre-upgrade             # snapshot current root before a major change
debz-be rollback rpool/ROOT/<h>@pre-upgrade  # roll back if something goes wrong
debz-be activate rpool/ROOT/<h>@pre-upgrade  # set a snapshot as next boot target
debz-be delete rpool/ROOT/<h>@old      # clean up old boot environments
```

### ZFS dataset layout

Each major subtree is its own dataset — rolling back `/` doesn't affect `/home` or `/var/lib`. Service state survives OS rollbacks. Logs survive. Home directories survive.

```bash
# Add a dataset for a new user (survives OS rollbacks, independent snapshots)
zfs create -o mountpoint=/home/alice rpool/home/alice
chown alice:alice /home/alice

# Add a workload dataset under /srv
zfs create rpool/srv/myapp
```

### Hypervisor guest tools

At install time debz auto-detects the hypervisor and installs the appropriate guest agent:

| Hypervisor | Installed |
|------------|-----------|
| KVM / QEMU / Proxmox | `qemu-guest-agent` |
| VMware / ESXi | `open-vm-tools` |
| Xen | `xe-guest-utilities` |

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

Served at `https://<ip>:8080` on the live system. Single port — HTTP static files and WebSocket on the same connection.

- **Dashboard** — hostname, uptime, CPU, memory, NIC status
- **Install** — target selector, disk wipe, encrypted or plain ZFS, live progress log
- **ZFS** — pool status, snapshot list, snapshot create/rollback, boot environment management

Backend: Python asyncio + websockets. No framework dependencies beyond the standard library and `websockets`.

---

## License

BSD 3-Clause. See [LICENSE](LICENSE).

Third-party components (Linux kernel, OpenZFS, GNOME, etc.) retain their own licenses. All GPL/AGPL components are installed unmodified from official Debian APT repositories — source available from `deb-src` entries.

---

## Pro edition

The free edition installs the foundation. **debz Pro** adds 1-touch cluster deployment, golden image management, node orchestration, and automated networking. See [debz.ca](https://debz.ca) for details.
