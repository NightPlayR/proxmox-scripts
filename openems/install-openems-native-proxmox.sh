#!/usr/bin/env bash
# OpenEMS Edge native (no Docker) PoC on Proxmox VE - Debian 12 cloud image.
# Run as root ON a Proxmox VE x86_64 node.
set -Eeuo pipefail

VMID="${VMID:-411}"
VMNAME="${VMNAME:-openems-poc}"
STORAGE="${STORAGE:-local-lvm}"
SNIPPET_STORAGE="${SNIPPET_STORAGE:-local}"
BRIDGE="${BRIDGE:-vmbr0}"
MEMORY="${MEMORY:-4096}"
CORES="${CORES:-2}"
DISK_GB="${DISK_GB:-25}"
SSH_PUBKEY="${SSH_PUBKEY:-/root/.ssh/id_ed25519.pub}"
OPENEMS_VERSION="${OPENEMS_VERSION:-2026.10.0}"
IMAGE_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"
WORKDIR="/var/tmp/openems-poc-${VMID}"
SNIPPET_NAME="openems-native-${VMID}.yaml"

log(){ printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }
[[ "$(id -u)" == 0 ]] || die "Run as root on Proxmox"
[[ "$(uname -m)" == x86_64 ]] || die "This script expects x86_64 Proxmox"
command -v qm >/dev/null || die "qm missing; run on Proxmox VE node"
command -v pvesm >/dev/null || die "pvesm missing"
command -v curl >/dev/null || die "curl missing"
[[ "$VMID" =~ ^[0-9]+$ ]] || die "VMID must be numeric"
[[ "$DISK_GB" =~ ^[0-9]+$ ]] || die "DISK_GB must be numeric"
qm status "$VMID" >/dev/null 2>&1 && die "VMID $VMID already exists: nothing changed"
pvesm status --storage "$STORAGE" >/dev/null 2>&1 || die "VM storage $STORAGE not accessible"
pvesm status --storage "$SNIPPET_STORAGE" >/dev/null 2>&1 || die "Snippet storage $SNIPPET_STORAGE not accessible"
SNIP_PATH="$(pvesm path "${SNIPPET_STORAGE}:snippets/${SNIPPET_NAME}" 2>/dev/null || true)"
[[ -n "$SNIP_PATH" ]] || die "Snippet storage $SNIPPET_STORAGE must support snippets. Enable 'Snippets' content in Datacenter > Storage."
[[ -f "$SSH_PUBKEY" ]] || die "SSH public key not found: $SSH_PUBKEY. Specify SSH_PUBKEY=/path/to/key.pub"
[[ -d "/sys/class/net/${BRIDGE}" ]] || die "Network bridge $BRIDGE not found"
[[ "$MEMORY" =~ ^[0-9]+$ && "$CORES" =~ ^[0-9]+$ ]] || die "MEMORY and CORES must be numeric"
[[ ! -e "$SNIP_PATH" ]] || die "Snippet $SNIP_PATH already exists; choose a different VMID"

cat <<SUMMARY
Native OpenEMS PoC parameters:
  VMID: $VMID             Name: $VMNAME
  VM disk: $STORAGE / ${DISK_GB}G
  Cloud-init: $SNIPPET_STORAGE
  Bridge: $BRIDGE         DHCP: yes
  CPU/RAM: $CORES / ${MEMORY}MB
  SSH public key: $SSH_PUBKEY
  OpenEMS: $OPENEMS_VERSION
No existing VM will be overwritten. The new VM will boot automatically.
SUMMARY
if [[ "${AUTO_CONFIRM:-no}" != yes ]]; then
  read -r -p 'Create VM? Type YES: ' confirmation
  [[ "$confirmation" == YES ]] || die "Cancelled"
fi

mkdir -p "$WORKDIR" "$(dirname "$SNIP_PATH")"
log "Downloading official Debian 12 cloud image"
curl --fail --location --retry 3 --connect-timeout 20 "$IMAGE_URL" -o "$WORKDIR/debian12.qcow2"
qemu-img info "$WORKDIR/debian12.qcow2" >/dev/null || die "Downloaded cloud image invalid"

# Script executed INSIDE Debian VM on first cloud-init boot.
cat > "$WORKDIR/setup-in-guest.sh" <<'GUEST'
#!/usr/bin/env bash
set -Eeuo pipefail
exec > >(tee -a /var/log/openems-install.log) 2>&1
export DEBIAN_FRONTEND=noninteractive
printf '\n==== OpenEMS native installation: %s ====\n' "$(date -Is)"
apt-get update
apt-get install -y ca-certificates curl wget gnupg python3 jq qemu-guest-agent
systemctl enable --now qemu-guest-agent || true
# Install Temurin 21 JRE from vendor APT repository, rather than Debian 12 default Java 17.
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public \
  | gpg --dearmor -o /etc/apt/keyrings/adoptium.gpg
chmod 644 /etc/apt/keyrings/adoptium.gpg
printf 'deb [signed-by=/etc/apt/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb bookworm main\n' > /etc/apt/sources.list.d/adoptium.list
apt-get update
apt-get install -y temurin-21-jre
java -version
install -d -m 0755 /usr/lib/openems /etc/openems.d

# Resolve the official asset from the specified OpenEMS GitHub release.
VERSION="__OPENEMS_VERSION__"
python3 - "$VERSION" <<'PY'
import json, sys, urllib.request, os
version = sys.argv[1]
api = f'https://api.github.com/repos/OpenEMS/openems/releases/tags/{version}'
req = urllib.request.Request(api, headers={'User-Agent':'OpenEMS-PoC-installer','Accept':'application/vnd.github+json'})
with urllib.request.urlopen(req, timeout=30) as r:
    release = json.load(r)
assets = release.get('assets', [])
items = [a for a in assets if a.get('name') == 'openems-edge.jar']
if len(items) != 1:
    names = ', '.join(a.get('name','?') for a in assets)
    sys.exit(f'ERROR: Cannot identify exact openems-edge.jar asset in {version}. Assets: {names}')
url = items[0]['browser_download_url']
print('Downloading verified official release asset:', url)
req = urllib.request.Request(url, headers={'User-Agent':'OpenEMS-PoC-installer'})
with urllib.request.urlopen(req, timeout=180) as r, open('/usr/lib/openems/openems-edge.jar.tmp','wb') as out:
    while True:
        part = r.read(1024*1024)
        if not part: break
        out.write(part)
if os.path.getsize('/usr/lib/openems/openems-edge.jar.tmp') < 1024*1024:
    sys.exit('Downloaded JAR unexpectedly small; installation stopped')
os.replace('/usr/lib/openems/openems-edge.jar.tmp','/usr/lib/openems/openems-edge.jar')
PY

# Mirrors the official OpenEMS native deployment guidance.
cat > /etc/systemd/system/openems.service <<'SERVICE'
[Unit]
Description=OpenEMS Edge (native)
Wants=network-online.target
After=network-online.target

[Service]
User=root
Group=root
Type=notify
WorkingDirectory=/usr/lib/openems
ExecStart=/usr/bin/java -Dfelix.cm.dir=/etc/openems.d/ -jar /usr/lib/openems/openems-edge.jar
SuccessExitStatus=143
Restart=always
RestartSec=10
WatchdogSec=60

[Install]
WantedBy=multi-user.target
SERVICE
systemctl daemon-reload
systemctl enable --now openems
sleep 12
systemctl --no-pager -l status openems || true
printf '\nDONE. OpenEMS Edge systemd service installed.\n'
printf 'Check: systemctl status openems ; journalctl -u openems -f\n'
printf 'Felix: http://VM-IP:8080/system/console/configMgr (if the Web Console component is configured)\n'
printf 'NOTE: OpenEMS UI is a separate component; not included in native Edge install.\n'
GUEST
sed -i "s/__OPENEMS_VERSION__/${OPENEMS_VERSION}/g" "$WORKDIR/setup-in-guest.sh"

# Cloud-init custom user-data; login/SSH keys and DHCP are controlled by Proxmox ciuser/sshkeys/ipconfig0.
{
  printf '#cloud-config\n'
  printf 'package_update: false\n'
  printf 'disable_root: false\nssh_pwauth: false\n'
  printf 'users:\n  - name: root\n    lock_passwd: true\n    ssh_authorized_keys:\n'
  printf '      - %s\n' "$(cat "$SSH_PUBKEY")"
  printf 'write_files:\n'
  printf '  - path: /root/setup-openems-native.sh\n'
  printf '    permissions: "0750"\n'
  printf '    owner: root:root\n'
  printf '    content: |\n'
  sed 's/^/      /' "$WORKDIR/setup-in-guest.sh"
  printf 'runcmd:\n'
  printf '  - [bash, /root/setup-openems-native.sh]\n'
} > "$SNIP_PATH"

log "Creating VM $VMID"
qm create "$VMID" --name "$VMNAME" --memory "$MEMORY" --cores "$CORES" \
   --cpu host --machine q35 --ostype l26 \
   --net0 "virtio,bridge=${BRIDGE}" --agent enabled=1 \
   --scsihw virtio-scsi-single --onboot 1
log "Importing Debian disk (may take several minutes)"
qm importdisk "$VMID" "$WORKDIR/debian12.qcow2" "$STORAGE"
# Import usually creates unused0. Read actual generated volid; don't guess based on storage backend.
DISK_VOL="$(qm config "$VMID" | sed -n 's/^unused0: \([^,]*\).*$/\1/p')"
[[ -n "$DISK_VOL" ]] || die "Disk imported but unused0 missing. Inspect 'qm config $VMID' manually"
qm set "$VMID" --scsi0 "$DISK_VOL,discard=on,ssd=1"
qm resize "$VMID" scsi0 "${DISK_GB}G"
qm set "$VMID" --ide2 "${STORAGE}:cloudinit"
qm set "$VMID" --boot order=scsi0 --serial0 socket --vga serial0
qm set "$VMID" --ciuser root --sshkeys "$SSH_PUBKEY" --ipconfig0 ip=dhcp
qm set "$VMID" --cicustom "user=${SNIPPET_STORAGE}:snippets/${SNIPPET_NAME}"
qm cloudinit update "$VMID"
log "Starting VM $VMID"
qm start "$VMID"
cat <<END

VM $VMID started. Native installation continues in guest cloud-init (may take 5-15 min).
Find the DHCP address in your router/Proxmox console.
SSH login: ssh root@<VM-IP>   (using private key matching $SSH_PUBKEY)
In VM:
  cloud-init status --wait
  tail -100 /var/log/openems-install.log
  systemctl status openems
  journalctl -u openems -n 100 --no-pager
Felix after startup: http://<VM-IP>:8080/system/console/configMgr
Note: UI NOT installed; native Edge service only, fully without Docker.
Check security before exposing any ports outside your trusted LAN.
END
