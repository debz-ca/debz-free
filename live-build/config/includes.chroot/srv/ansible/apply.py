#!/usr/bin/env python3
"""
KubeOS Darksite cluster apply script

High-level phases:
  1) Wait for salt minions
  2) Ensure local WireGuard keys exist
  3) Regenerate wg1/wg2/wg3 configs from seed and restart wg-quick units
  4) Ensure ansible user + SSH key on master, push pubkey to all minions via salt
  5) Seed a UNIT-scoped known_hosts file (both hostnames + ansible_host IPs)
  6) Wait until all inventory ansible_host IPs accept TCP/22 (WG/sshd settle gate)
  7) Run ansible ping and then ansible-playbook site.yml

Notes:
  - Ansible connects over management plane (typically 10.78.0.0/24 via WG).
  - Cluster services (k8s/etcd/etc) should bind/advertise on underlay (10.100.0.0/24),
    which is handled by the Ansible roles/inventory vars, not by this script.
  - Host key handling is isolated to UNIT_KNOWN_HOSTS (default /srv/darksite/known_hosts)
    to avoid mutating /home/ansible/.ssh/known_hosts and to keep runs deterministic.
"""

import json
import os
import shutil
import shlex
import socket
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Set, Tuple

# -----------------------------
# Paths / constants
# -----------------------------
WG_DIR = Path("/etc/wireguard")
PLANES = ["wg1", "wg2", "wg3"]
SYSTEMD_UNIT_TEMPLATE = "wg-quick@{iface}.service"

SEED_PATHS = [
    Path("/root/darksite/cluster-seed/peers.json"),
    Path("/root/darksite/cluster-seed.json"),
]

ANSIBLE_BASE = Path("/srv/ansible")
ANSIBLE_INVENTORY = ANSIBLE_BASE / "inventory" / "hosts.ini"
ANSIBLE_SITE = ANSIBLE_BASE / "site.yml"

ANSIBLE_USER = "ansible"
ANSIBLE_HOME = Path("/home/ansible")
ANSIBLE_SSH_DIR = ANSIBLE_HOME / ".ssh"
ANSIBLE_PRIVKEY = ANSIBLE_SSH_DIR / "id_ed25519"
ANSIBLE_PUBKEY = ANSIBLE_SSH_DIR / "id_ed25519.pub"

# Unit-scoped known_hosts (do not touch user homedir known_hosts)
UNIT_KNOWN_HOSTS = Path(os.environ.get("KUBEOS_KNOWN_HOSTS", "/srv/darksite/known_hosts"))
UNIT_DIR = UNIT_KNOWN_HOSTS.parent

SALT_TARGET = "*"
SALT_PING_RETRIES = int(os.environ.get("KUBEOS_SALT_PING_RETRIES", "80"))
SALT_PING_SLEEP = int(os.environ.get("KUBEOS_SALT_PING_SLEEP", "3"))
SALT_EXPECTED_MINIONS = int(os.environ.get("KUBEOS_SALT_EXPECTED_MINIONS", "15"))
SALT_REQUIRE_ALL = os.environ.get("KUBEOS_SALT_REQUIRE_ALL", "1") == "1"

POST_BOOT_PAUSE_SECONDS = int(os.environ.get("KUBEOS_POST_BOOT_PAUSE", "10"))

BACKUP_KEEP = int(os.environ.get("KUBEOS_WG_BACKUP_KEEP", "10") or "10")
ANSIBLE_STRICT = os.environ.get("KUBEOS_ANSIBLE_STRICT", "0") == "1"
ANSIBLE_VERBOSE = os.environ.get("KUBEOS_ANSIBLE_VERBOSE", "-vvv")  # "-v", "-vv", "-vvv"
ANSIBLE_COLOR = os.environ.get("KUBEOS_ANSIBLE_COLOR", "1") == "1"

# SSH behavioral toggles
SSH_ACCEPT_NEW = os.environ.get("KUBEOS_SSH_ACCEPT_NEW", "1") == "1"  # accept-new host keys to unit file
SSH_STRICT = os.environ.get("KUBEOS_SSH_STRICT", "0") == "1"          # if 1, strict checking against unit file

# Reachability gate
ANSIBLE_REACHABILITY_TIMEOUT = int(os.environ.get("KUBEOS_ANSIBLE_REACHABILITY_TIMEOUT", "180"))


# -----------------------------
# Helpers
# -----------------------------
def log(msg: str) -> None:
    print(msg, flush=True)


def run(
    cmd: List[str],
    check: bool = True,
    env: Optional[Dict[str, str]] = None,
    cwd: Optional[Path] = None,
    timeout: Optional[int] = None,
    **kwargs,
) -> str:
    kwargs.setdefault("text", True)
    kwargs.setdefault("stdout", subprocess.PIPE)
    kwargs.setdefault("stderr", subprocess.STDOUT)
    p = subprocess.run(cmd, check=check, env=env, cwd=str(cwd) if cwd else None, timeout=timeout, **kwargs)
    return (p.stdout or "").strip()


def run_rc(
    cmd: List[str],
    env: Optional[Dict[str, str]] = None,
    cwd: Optional[Path] = None,
    timeout: Optional[int] = None,
    **kwargs,
) -> Tuple[int, str]:
    kwargs.setdefault("text", True)
    kwargs.setdefault("stdout", subprocess.PIPE)
    kwargs.setdefault("stderr", subprocess.STDOUT)
    p = subprocess.run(cmd, check=False, env=env, cwd=str(cwd) if cwd else None, timeout=timeout, **kwargs)
    return p.returncode, (p.stdout or "").strip()


def sh(cmd: str, check: bool = True, timeout: Optional[int] = None) -> str:
    """Run a shell command via bash -lc (convenience helper)."""
    return run(["bash", "-lc", cmd], check=check, timeout=timeout)


def run_stream(
    cmd: List[str],
    env: Optional[Dict[str, str]] = None,
    cwd: Optional[Path] = None,
    timeout: Optional[int] = None,
) -> int:
    """
    Stream stdout/stderr in real time. Returns process return code.
    """
    p = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
        env=env,
        cwd=str(cwd) if cwd else None,
    )
    assert p.stdout is not None
    start = time.time()
    for line in p.stdout:
        sys.stdout.write(line)
        sys.stdout.flush()
        if timeout and (time.time() - start) > timeout:
            p.kill()
            return 124
    return p.wait()


def is_master() -> bool:
    hn = run(["hostname", "-f"], check=False).lower()
    return hn.startswith("master.") or hn == "master"


def hostname_fqdn() -> str:
    return run(["hostname", "-f"], check=False) or run(["hostname", "-s"], check=False)


def load_seed() -> Dict[str, Any]:
    for p in SEED_PATHS:
        if p.exists():
            return json.loads(p.read_text())
    raise RuntimeError(f"Seed file not found. Tried: {', '.join(str(p) for p in SEED_PATHS)}")


def _extract_json_object(text: str) -> Optional[Dict[str, Any]]:
    """
    Salt output can include non-json banners. Extract last {...} block.
    """
    if not text:
        return None
    s = text.find("{")
    e = text.rfind("}")
    if s == -1 or e == -1 or e <= s:
        return None
    try:
        return json.loads(text[s: e + 1])
    except Exception:
        return None


# -----------------------------
# Salt helpers
# -----------------------------
def salt_cmd(target: str, shell_cmd: str, retries: int = 2) -> Dict[str, Any]:
    """
    Run salt cmd.run and return JSON dict (minion->output).
    Retries a couple times to ride through transient salt/mine hiccups.
    """
    last_err = None
    for _ in range(retries + 1):
        rc, out = run_rc(
            ["salt", target, "cmd.run", shell_cmd, "--out=json", "--static", "--no-color"],
            timeout=90,
        )
        if rc == 0:
            data = _extract_json_object(out)
            if isinstance(data, dict):
                return data
        last_err = out
        time.sleep(1)
    if last_err:
        log(f"[WARN] salt_cmd failed target={target}: {last_err[:300]}")
    return {}


def salt_ping_wait() -> None:
    """
    Wait for salt minions to respond. By default requires all expected minions.
    """
    log("[INFO] waiting for salt minions ...")
    for _ in range(SALT_PING_RETRIES):
        rc, out = run_rc(["salt", SALT_TARGET, "test.ping", "--out=json", "--static", "--no-color"], timeout=30)
        if rc == 0:
            data = _extract_json_object(out)
            if isinstance(data, dict):
                up = [k for k, v in data.items() if v is True]
                if SALT_REQUIRE_ALL:
                    if len(up) >= SALT_EXPECTED_MINIONS:
                        log(f"[INFO] salt up: {len(up)} (expected={SALT_EXPECTED_MINIONS})")
                        return
                else:
                    if up:
                        log(f"[INFO] salt up: {len(up)}")
                        return
        time.sleep(SALT_PING_SLEEP)
    raise RuntimeError("salt minions did not respond in time")


# -----------------------------
# WireGuard helpers
# -----------------------------
def ensure_wg_keys_local(iface: str) -> None:
    key = WG_DIR / f"{iface}.key"
    pub = WG_DIR / f"{iface}.pub"
    if key.exists() and pub.exists():
        return
    key.parent.mkdir(parents=True, exist_ok=True)
    old_umask = os.umask(0o077)
    try:
        private = run(["wg", "genkey"], check=True) + "\n"
        key.write_text(private)
        pubkey = run(["bash", "-lc", f"wg pubkey < {shlex.quote(str(key))}"], check=True) + "\n"
        pub.write_text(pubkey)
    finally:
        os.umask(old_umask)


def read_iface_block(conf_path: Path) -> List[str]:
    lines: List[str] = []
    for line in conf_path.read_text(errors="replace").splitlines():
        if line.strip().startswith("[Peer]"):
            break
        lines.append(line)
    return lines


def prune_backups(conf_path: Path) -> None:
    if BACKUP_KEEP <= 0:
        return
    backups = sorted(conf_path.parent.glob(f"{conf_path.name}.bak.*"))
    excess = len(backups) - (BACKUP_KEEP - 1)
    if excess > 0:
        for old in backups[:excess]:
            try:
                old.unlink()
            except Exception:
                pass


def write_if_changed(conf_path: Path, desired_text: str) -> bool:
    current = conf_path.read_text(errors="replace") if conf_path.exists() else ""
    if current == desired_text:
        return False

    if conf_path.exists() and BACKUP_KEEP > 0:
        prune_backups(conf_path)
        ts = time.strftime("%Y%m%d%H%M%S")
        backup_path = conf_path.with_suffix(conf_path.suffix + f".bak.{ts}")
        shutil.copy2(conf_path, backup_path)

    tmp = conf_path.with_suffix(conf_path.suffix + ".new")
    tmp.write_text(desired_text)
    os.replace(tmp, conf_path)
    return True


def render_plane_conf_from_seed(seed: Dict[str, Any], iface: str) -> Tuple[Path, bool]:
    """
    Render a wg*.conf.
      - On master: write peers for all nodes (hub)
      - On minions: write single peer to master (spoke)
    """
    conf_path = WG_DIR / f"{iface}.conf"
    if not conf_path.exists():
        raise RuntimeError(f"missing {conf_path} (base interface config must exist)")

    iface_lines = read_iface_block(conf_path)

    hn = hostname_fqdn().lower()
    nodes: Dict[str, Any] = seed["nodes"]

    # Normalize hostname lookup
    if hn not in (k.lower() for k in nodes.keys()):
        short = run(["hostname", "-s"], check=False).lower()
        match = None
        for k in nodes.keys():
            kl = k.lower()
            if kl.startswith(short + ".") or kl == short:
                match = k
                break
        if not match:
            raise RuntimeError(f"this node ({hn}) not found in seed nodes")
        hn = match.lower()

    # Find canonical key in nodes dict
    canonical = None
    for k in nodes.keys():
        if k.lower() == hn:
            canonical = k
            break
    if canonical is None:
        raise RuntimeError(f"this node ({hn}) not found in seed nodes (canonical lookup failed)")

    me = nodes[canonical]
    my_ip = me.get(iface)
    if not my_ip:
        raise RuntimeError(f"seed missing {iface} ip for {canonical}")

    desired: List[str] = []
    desired.extend(iface_lines)
    desired.append("")

    if is_master():
        pubkeys = salt_cmd(SALT_TARGET, f"cat /etc/wireguard/{iface}.pub 2>/dev/null | tr -d '\\n' || true")
        # Ensure master's pubkey is included even if salt doesn't return it
        my_pub_path = WG_DIR / f"{iface}.pub"
        if my_pub_path.exists():
            pubkeys[hostname_fqdn()] = my_pub_path.read_text().strip()

        for node_name, node in sorted(nodes.items(), key=lambda x: x[0]):
            ip = node.get(iface)
            if not ip or ip == my_ip:
                continue
            pk = (pubkeys.get(node_name) or "").strip()
            if not pk:
                continue
            desired.append("[Peer]")
            desired.append(f"# {node_name} ({iface})")
            desired.append(f"PublicKey = {pk}")
            desired.append(f"AllowedIPs = {ip}/32")
            desired.append("PersistentKeepalive = 25")
            desired.append("")
    else:
        master_name = next((n for n in nodes.keys() if n.lower().startswith("master.")), None)
        if not master_name:
            raise RuntimeError("seed has no master.* entry")
        master = nodes[master_name]
        pk = salt_cmd("master*", f"cat /etc/wireguard/{iface}.pub 2>/dev/null | tr -d '\\n' || true")
        master_pk = ""
        for _, v in pk.items():
            master_pk = (v or "").strip()
            if master_pk:
                break
        if not master_pk:
            raise RuntimeError(f"could not obtain master {iface} pubkey via salt")

        # On spokes, AllowedIPs should typically be the whole plane CIDR so minion can reach any peer via hub
        plane_cidr = seed.get("planes", {}).get(iface, {}).get("cidr")
        if not plane_cidr:
            raise RuntimeError(f"seed missing planes.{iface}.cidr")

        desired.append("[Peer]")
        desired.append(f"# {master_name} ({iface})")
        desired.append(f"PublicKey = {master_pk}")
        desired.append(f"AllowedIPs = {plane_cidr}")
        desired.append(f"Endpoint = {master['endpoint']}:{seed['planes'][iface]['port']}")
        desired.append("PersistentKeepalive = 25")
        desired.append("")

    desired_text = "\n".join(desired).rstrip() + "\n"
    changed = write_if_changed(conf_path, desired_text)
    return conf_path, changed


def restart_plane(iface: str) -> None:
    unit = SYSTEMD_UNIT_TEMPLATE.format(iface=iface)
    run(["systemctl", "restart", unit], check=False)


# -----------------------------
# Inventory / SSH gating
# -----------------------------
def inventory_targets() -> List[Tuple[str, str]]:
    """
    Parse the INI-style inventory and return [(hostname, ansible_host_ip), ...].
    Only lines with a hostname token (not [group]) are considered.
    """
    if not ANSIBLE_INVENTORY.exists():
        return []
    targets: List[Tuple[str, str]] = []
    for raw in ANSIBLE_INVENTORY.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or line.startswith(";"):
            continue
        if line.startswith("[") and line.endswith("]"):
            continue
        parts = line.split()
        if not parts:
            continue
        host = parts[0]
        if host.startswith("["):
            continue
        ansible_host = ""
        for p in parts[1:]:
            if p.startswith("ansible_host="):
                ansible_host = p.split("=", 1)[1].strip()
                break
        if ansible_host:
            targets.append((host, ansible_host))
    # de-dupe while preserving order
    seen: Set[Tuple[str, str]] = set()
    uniq: List[Tuple[str, str]] = []
    for h, ip in targets:
        key = (h, ip)
        if key not in seen:
            seen.add(key)
            uniq.append(key)
    return uniq


def wait_for_tcp(
    host: str,
    port: int,
    timeout_s: int = 120,
    per_try_timeout_s: float = 1.0,
    *,
    debug: bool = False,
) -> Tuple[bool, str]:
    """Try to connect to TCP host:port until timeout. Returns (ok, last_error_str)."""
    deadline = time.time() + timeout_s
    last_err: Optional[OSError] = None
    while time.time() < deadline:
        try:
            with socket.create_connection((host, port), timeout=per_try_timeout_s):
                return True, ""
        except OSError as e:
            last_err = e
            time.sleep(0.5)
    err_s = str(last_err) if last_err else "timeout"
    if debug:
        log(f"[DEBUG] tcp check failed for {host}:{port}: {err_s}")
    return False, err_s

def wait_for_ansible_reachability(timeout_s: int = 240) -> None:
    """
    After WireGuard is (re)configured, routes + peer endpoints + sshd can take a moment.
    This gate prevents the first 'ansible -m ping' from flapping with 'No route to host'.
    """
    targets = inventory_targets()
    if not targets:
        log("[WARN] no inventory targets found; skipping reachability wait")
        return

    # Only check management-plane targets (ansible_host). Skip localhost entries.
    ips: List[str] = []
    for _, ip in targets:
        if ip in ("localhost",) or ip.startswith("127."):
            continue
        ips.append(ip)

    if not ips:
        log("[WARN] inventory only contains localhost targets; skipping reachability wait")
        return

    # Kick WireGuard handshakes a bit (some peers only become reachable after their first keepalive).
    for ip in ips:
        run_rc(["ping", "-c1", "-W1", ip], timeout=2)

    log(f"[INFO] waiting for ssh reachability on mgmt plane (targets={len(ips)})")
    deadline = time.time() + timeout_s
    remaining = set(ips)
    last_err: Dict[str, str] = {}
    last_report = 0.0

    while remaining and time.time() < deadline:
        done: Set[str] = set()

        for ip in sorted(remaining):
            # Route sanity check first (avoids noisy socket errors while wg-quick is restarting).
            rc, route_out = run_rc(["ip", "route", "get", ip], timeout=3)
            if rc != 0:
                last_err[ip] = "no route"
                continue
            # If route exists, check TCP/22 quickly.
            ok, err = wait_for_tcp(ip, 22, timeout_s=2, per_try_timeout_s=1.0, debug=False)
            if ok:
                done.add(ip)
            else:
                last_err[ip] = err or "tcp connect failed"

        remaining -= done
        if not remaining:
            break

        # Periodic progress log (every ~15s)
        now = time.time()
        if now - last_report > 15:
            sample = ", ".join(sorted(list(remaining))[:6])
            more = "" if len(remaining) <= 6 else f" (+{len(remaining)-6} more)"
            log(f"[INFO] still waiting for ssh on: {sample}{more}")
            last_report = now

        time.sleep(1.5)

    if remaining:
        # Collapse errors into a readable summary
        parts = []
        for ip in sorted(remaining):
            parts.append(f"{ip} ({last_err.get(ip,'unknown')})")
        log(f"[WARN] some hosts still not reachable on TCP/22 after {timeout_s}s: " + ", ".join(parts))
    else:
        log("[INFO] ssh reachability OK for all targets")

def ensure_unit_known_hosts() -> None:
    """
    Create + seed a unit-scoped known_hosts file used by Ansible/ssh.
    We pre-populate both hostnames and ansible_host IPs so StrictHostKeyChecking
    can be enabled without interactive prompts.
    """
    UNIT_DIR.mkdir(parents=True, exist_ok=True)

    sh(f"install -d -m0700 -o {ANSIBLE_USER} -g {ANSIBLE_USER} {shlex.quote(str(UNIT_DIR))}")
    sh(f"touch {shlex.quote(str(UNIT_KNOWN_HOSTS))}")
    sh(f"chown {ANSIBLE_USER}:{ANSIBLE_USER} {shlex.quote(str(UNIT_KNOWN_HOSTS))}")
    sh(f"chmod 0600 {shlex.quote(str(UNIT_KNOWN_HOSTS))}")

    targets = inventory_targets()
    if not targets:
        log("[WARN] no inventory targets found; skipping known_hosts seeding")
        return

    scan_items: List[str] = []
    for host, ip in targets:
        scan_items.append(host)
        scan_items.append(ip)
    # de-dupe preserve order
    seen: Set[str] = set()
    scan_items = [x for x in scan_items if not (x in seen or seen.add(x))]

    log(f"[INFO] seeding unit known_hosts for {len(scan_items)} host entries")

    items = " ".join(shlex.quote(x) for x in scan_items)
    seed_script = f"""set -euo pipefail
KH={shlex.quote(str(UNIT_KNOWN_HOSTS))}
tmp="$(mktemp)"
touch "$tmp"
for h in {items}; do
  ssh-keyscan -T 3 -H "$h" 2>/dev/null >> "$tmp" || true
done
cat "$KH" "$tmp" | awk '!seen[$0]++' > "$KH.new" || true
mv "$KH.new" "$KH" || true
rm -f "$tmp"
"""

    rc, out = run_rc(["sudo", "-H", "-u", ANSIBLE_USER, "bash", "-lc", seed_script])
    if rc != 0:
        log(f"[WARN] known_hosts seeding returned rc={rc}; continuing\n{out}")


# -----------------------------
# Ansible user/key bootstrap via salt
# -----------------------------
def ensure_ansible_user_on_master() -> str:
    """
    Ensure ansible user exists on master and has an ed25519 keypair.
    Returns the public key (single line).
    """
    log("[INFO] ensuring ansible user + key on master")

    # Ensure user exists
    sh(f"id -u {ANSIBLE_USER} >/dev/null 2>&1 || useradd -m -s /bin/bash {ANSIBLE_USER}", check=False)

    # Ensure sudo without password (typical for automation)
    sudoers = Path(f"/etc/sudoers.d/{ANSIBLE_USER}")
    if not sudoers.exists():
        sudoers.write_text(f"{ANSIBLE_USER} ALL=(ALL) NOPASSWD:ALL\n")
        sudoers.chmod(0o440)

    # Ensure ssh dir
    sh(f"install -d -m0700 -o {ANSIBLE_USER} -g {ANSIBLE_USER} {shlex.quote(str(ANSIBLE_SSH_DIR))}")

    # Generate keypair if missing
    if not ANSIBLE_PRIVKEY.exists() or not ANSIBLE_PUBKEY.exists():
        sh(
            f"sudo -H -u {ANSIBLE_USER} ssh-keygen -t ed25519 -N '' -f {shlex.quote(str(ANSIBLE_PRIVKEY))}",
            check=True,
        )

    pub = ANSIBLE_PUBKEY.read_text().strip()
    if not pub:
        raise RuntimeError("ansible public key is empty")
    return pub


def push_ansible_key_to_minions(pubkey: str) -> None:
    """
    Push ansible user's authorized_keys to all minions via salt.
    """
    log("[INFO] pushing ansible key to minions via salt")

    # Use a heredoc to avoid quoting issues; salt cmd.run executes in sh
    script = f"""set -e
id -u {ANSIBLE_USER} >/dev/null 2>&1 || useradd -m -s /bin/bash {ANSIBLE_USER}
install -d -m0700 -o {ANSIBLE_USER} -g {ANSIBLE_USER} /home/{ANSIBLE_USER}/.ssh
touch /home/{ANSIBLE_USER}/.ssh/authorized_keys
grep -qxF {shlex.quote(pubkey)} /home/{ANSIBLE_USER}/.ssh/authorized_keys || echo {shlex.quote(pubkey)} >> /home/{ANSIBLE_USER}/.ssh/authorized_keys
chown {ANSIBLE_USER}:{ANSIBLE_USER} /home/{ANSIBLE_USER}/.ssh/authorized_keys
chmod 0600 /home/{ANSIBLE_USER}/.ssh/authorized_keys
"""

    _ = salt_cmd(SALT_TARGET, f"bash -lc {shlex.quote(script)}", retries=1)


def ensure_controller_artifact_perms() -> None:
    """
    Ensure ansible (or sudo -u ansible tasks) can access controller-side artifacts directory.
    """
    log("[INFO] ensuring controller artifact permissions for ansible")

    # Common locations used by roles
    for p in [
        Path("/srv/ansible/artifacts"),
        Path("/srv/ansible/artifacts/etcd-pki"),
        Path("/srv/darksite"),
    ]:
        try:
            p.mkdir(parents=True, exist_ok=True)
        except Exception:
            pass

    # Make sure ansible can read/write artifacts (group = ansible)
    sh("getent group ansible >/dev/null 2>&1 || groupadd ansible", check=False)
    sh(f"usermod -aG ansible {ANSIBLE_USER}", check=False)
    sh("chgrp -R ansible /srv/ansible/artifacts /srv/darksite 2>/dev/null || true", check=False)
    sh("chmod -R g+rwX /srv/ansible/artifacts /srv/darksite 2>/dev/null || true", check=False)


# -----------------------------
# Ansible execution
# -----------------------------
def ansible_env() -> Dict[str, str]:
    """
    Build environment for ansible runs to:
      - force correct key
      - isolate hostkey handling to unit file
      - reduce prompts / make deterministic
    """
    env = os.environ.copy()
    env["ANSIBLE_PRIVATE_KEY_FILE"] = str(ANSIBLE_PRIVKEY)

    strict = "yes" if SSH_STRICT else ("accept-new" if SSH_ACCEPT_NEW else "no")
    ssh_common = [
        f"-o UserKnownHostsFile={UNIT_KNOWN_HOSTS}",
        f"-o StrictHostKeyChecking={strict}",
        "-o LogLevel=ERROR",
        "-o ServerAliveInterval=15",
        "-o ServerAliveCountMax=3",
    ]
    env["ANSIBLE_SSH_COMMON_ARGS"] = " ".join(ssh_common)

    # Ansible output / verbosity
    env["ANSIBLE_STDOUT_CALLBACK"] = "default"
    env["ANSIBLE_LOAD_CALLBACK_PLUGINS"] = "1"
    if ANSIBLE_COLOR:
        env["ANSIBLE_FORCE_COLOR"] = "1"
    else:
        env["ANSIBLE_NOCOLOR"] = "1"

    # We control host key checking via SSH args; keep Ansible from prompting
    env["ANSIBLE_HOST_KEY_CHECKING"] = "False"
    return env


def ansible_ping_and_world() -> None:
    log("[INFO] running ansible ping + world")
    if not ANSIBLE_INVENTORY.exists():
        raise RuntimeError(f"missing ansible inventory: {ANSIBLE_INVENTORY}")
    if not ANSIBLE_SITE.exists():
        raise RuntimeError(f"missing ansible site: {ANSIBLE_SITE}")

    env = ansible_env()

    # Ping
    rc = run_stream(
        ["bash", "-lc", f"cd {shlex.quote(str(ANSIBLE_BASE))} && sudo -H -u {ANSIBLE_USER} ansible -v -i {shlex.quote(str(ANSIBLE_INVENTORY))} all -m ping"],
        env=env,
        timeout=600,
    )
    if rc != 0:
        raise RuntimeError(f"ansible ping failed rc={rc}")

    # Playbook
    rc2 = run_stream(
        ["bash", "-lc", f"cd {shlex.quote(str(ANSIBLE_BASE))} && sudo -H -u {ANSIBLE_USER} ansible-playbook {ANSIBLE_VERBOSE} -i {shlex.quote(str(ANSIBLE_INVENTORY))} {shlex.quote(str(ANSIBLE_SITE))}"],
        env=env,
        timeout=6 * 60 * 60,
    )
    if rc2 != 0:
        raise RuntimeError(f"ansible playbook failed rc={rc2}")


# -----------------------------
# Main
# -----------------------------
def main() -> None:
    log(f"[INFO] post-boot pause {POST_BOOT_PAUSE_SECONDS}s")
    time.sleep(POST_BOOT_PAUSE_SECONDS)

    seed = load_seed()

    for iface in PLANES:
        ensure_wg_keys_local(iface)

    salt_ping_wait()

    # WireGuard plane regeneration
    for iface in PLANES:
        conf_path, changed = render_plane_conf_from_seed(seed, iface)
        log(f"[INFO] {iface}: {'updated' if changed else 'unchanged'} {conf_path}")
        if changed:
            restart_plane(iface)

    # Allow some time for routes/handshakes to settle (still gated by TCP check later)
    log("[INFO] wg settle: sleeping 8s")
    time.sleep(8)

    # Seed unit known_hosts (prevents interactive prompts)
    ensure_unit_known_hosts()

    if is_master():
        try:
            pub = ensure_ansible_user_on_master()
            push_ansible_key_to_minions(pub)
            ensure_controller_artifact_perms()

            # Gate ansible until WG route + sshd are actually reachable
            wait_for_ansible_reachability(timeout_s=ANSIBLE_REACHABILITY_TIMEOUT)

            ansible_ping_and_world()
        except Exception as e:
            log(f"[WARN] ansible phase failed: {e}")
            if ANSIBLE_STRICT:
                raise

    # Mine refresh (non-fatal)
    run_rc(["bash", "-lc", "salt-call --local mine.update 2>/dev/null || true"])
    log("[INFO] DONE")


if __name__ == "__main__":
    main()
