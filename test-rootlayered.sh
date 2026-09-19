#!/bin/bash
#  End-to-end test for cloud-initramfs-rootlayered.
#  Copyright, 2024 Aleksandar Markovic
#
#  Downloads the maas.io noble ephemeral kernel/initrd, resolves a
#  comma-separated list of squashfs layers (maas/cloud/local files),
#  builds a small "upper" squashfs layer (NoCloud seed for password
#  login), stacks rootlayered into the base initrd, serves everything
#  over http, and boots the result in QEMU.
#
#  Must be run from the project root (expects ./local-top/rootlayered
#  to exist).

set -euo pipefail

SERIES="noble"
ARCH="amd64"
GA_VERSION="24.04"
MAAS_BASE="https://images.maas.io/ephemeral-v3/stable"
CLOUD_SQUASHFS_URL="https://cloud-images.ubuntu.com/${SERIES}/current/${SERIES}-server-cloudimg-amd64.squashfs"
HTTP_PORT=8000
WORK_DIR="$(pwd)/test-work"
MAAS_DIR="${WORK_DIR}/maas"
HTTPD_ROOT="${WORK_DIR}/httpd-root"
HTTPD_LOG="${WORK_DIR}/httpd.log"
INTERACTIVE=false
SOURCE="cloud"  # comma-separated layer list: maas, cloud, and/or /path/to/*.squashfs
RESOLVED_LAYERS=()

HTTPD_PID=""

info() { echo ">> $*"; }

check_deps() {
	local deps=(curl mksquashfs cpio gzip python3 qemu-system-x86_64)
	local missing=()
	local dep
	for dep in "${deps[@]}"; do
		command -v "$dep" &>/dev/null || missing+=("$dep")
	done
	if [[ ${#missing[@]} -gt 0 ]]; then
		echo "ERROR: missing required tools: ${missing[*]}" >&2
		return 1
	fi
	[[ -f "local-top/rootlayered" ]] || {
		echo "ERROR: local-top/rootlayered not found (run from project root)" >&2
		return 1
	}
}

# Find the latest dated snapshot directory under stable/<series>/<arch>/
find_latest_date_dir() {
	local url="$1" page dirs

	page=$(curl -fsSL "$url") || { echo "ERROR: failed to fetch $url" >&2; return 1; }
	dirs=$(grep -oP 'href="\K[0-9]+/(?=")' <<<"$page" || true)
	[[ -z "$dirs" ]] && { echo "ERROR: no dated directories found at $url" >&2; return 1; }

	echo "${url%/}/$(sort <<<"$dirs" | tail -1)"
}

# Find the ga-*/generic/ subdirectory containing boot-kernel/boot-initrd
# under a dated snapshot directory.
find_ga_generic_dir() {
	local url="$1" page ga_dirs chosen

	page=$(curl -fsSL "$url") || { echo "ERROR: failed to fetch $url" >&2; return 1; }
	ga_dirs=$(grep -oP 'href="\Kga-[^"?/]+/(?=")' <<<"$page" || true)
	[[ -z "$ga_dirs" ]] && { echo "ERROR: no ga-* directory found at $url" >&2; return 1; }

	# Prefer an exact match for the series' GA version if present,
	# otherwise take the lexically last one.
	if grep -qx "ga-${GA_VERSION}/" <<<"$ga_dirs"; then
		chosen="ga-${GA_VERSION}/"
	else
		chosen=$(sort <<<"$ga_dirs" | tail -1)
	fi

	echo "${url%/}/${chosen}generic/"
}

download_maas_kernel_initrd() {
	[[ -f "${MAAS_DIR}/boot-kernel" && -f "${MAAS_DIR}/boot-initrd" ]] && {
		info "maas kernel/initrd already downloaded, skipping"
		return 0
	}

	mkdir -p "${MAAS_DIR}"

	local base_url="${MAAS_BASE}/${SERIES}/${ARCH}/"
	info "Finding latest dated snapshot under ${base_url}"
	local date_dir
	date_dir=$(find_latest_date_dir "$base_url") || return 1
	info "Snapshot dir: ${date_dir}"

	local generic_dir
	generic_dir=$(find_ga_generic_dir "$date_dir") || return 1
	info "Kernel/initrd dir: ${generic_dir}"

	local f
	for f in boot-kernel boot-initrd; do
		info "Downloading ${f}"
		curl -fsSL "${generic_dir}${f}" -o "${MAAS_DIR}/${f}" || return 1
	done
}

download_maas_squashfs() {
	[[ -f "${MAAS_DIR}/maas-squashfs" ]] && {
		info "maas squashfs already downloaded, skipping"
		return 0
	}

	mkdir -p "${MAAS_DIR}"

	local base_url="${MAAS_BASE}/${SERIES}/${ARCH}/"
	info "Finding latest dated snapshot under ${base_url}"
	local date_dir
	date_dir=$(find_latest_date_dir "$base_url") || return 1
	info "Snapshot dir: ${date_dir}"

	info "Downloading maas squashfs"
	curl -fsSL "${date_dir}/squashfs" -o "${MAAS_DIR}/maas-squashfs" || return 1
}

download_cloud_squashfs() {
	[[ -f "${MAAS_DIR}/cloud-squashfs" ]] && {
		info "cloud image squashfs already downloaded, skipping"
		return 0
	}

	mkdir -p "${MAAS_DIR}"
	info "Downloading cloud image squashfs from ${CLOUD_SQUASHFS_URL}"
	curl -fsSL "${CLOUD_SQUASHFS_URL}" -o "${MAAS_DIR}/cloud-squashfs" || return 1
}

resolve_sources() {
	local specs spec path
	IFS=',' read -ra specs <<< "$SOURCE"
	RESOLVED_LAYERS=()

	for spec in "${specs[@]}"; do
		case "$spec" in
			maas)
				download_maas_squashfs || return 1
				path="${MAAS_DIR}/maas-squashfs"
				;;
			cloud)
				download_cloud_squashfs || return 1
				path="${MAAS_DIR}/cloud-squashfs"
				;;
			*)
				path=$(realpath -e "$spec" 2>/dev/null) || {
					echo "ERROR: squashfs source not found: $spec" >&2
					return 1
				}
				;;
		esac
		RESOLVED_LAYERS+=("$path")
	done
}

build_upper_squashfs() {
	[[ -f "${WORK_DIR}/upper.squashfs" ]] && {
		info "upper.squashfs already built, skipping"
		return 0
	}

	local root="${WORK_DIR}/upper-root"
	rm -rf "$root"

	# NoCloud seed: cloud-init auto-detects /var/lib/cloud/seed/nocloud/
	# without any kernel cmdline change, and sets a login password so we
	# can get an interactive console.
	mkdir -p "$root/var/lib/cloud/seed/nocloud"

	cat > "$root/var/lib/cloud/seed/nocloud/meta-data" <<EOF
instance-id: rootlayered-test
local-hostname: rootlayered-test
EOF

	cat > "$root/var/lib/cloud/seed/nocloud/user-data" <<'EOF'
#cloud-config
password: ubuntu
chpasswd:
  expire: false
ssh_pwauth: true
EOF

	info "Building upper.squashfs"
	mksquashfs "$root" "${WORK_DIR}/upper.squashfs" -noappend
}

setup_httpd_root() {
	mkdir -p "${HTTPD_ROOT}"

	ln -sf "${WORK_DIR}/upper.squashfs" "${HTTPD_ROOT}/upper.squashfs"

	local i
	for i in "${!RESOLVED_LAYERS[@]}"; do
		ln -sf "${RESOLVED_LAYERS[$i]}" "${HTTPD_ROOT}/layer${i}.squashfs"
	done
}

start_httpd() {
	info "Starting http server on :${HTTP_PORT} (log: ${HTTPD_LOG})"
	(cd "${HTTPD_ROOT}" && python3 -m http.server "${HTTP_PORT}") > "${HTTPD_LOG}" 2>&1 &
	HTTPD_PID=$!
	sleep 1
}

stop_httpd() {
	[[ -n "$HTTPD_PID" ]] && kill "$HTTPD_PID" 2>/dev/null || true
}

build_combined_initrd() {
	local extra="${WORK_DIR}/extra"
	rm -rf "$extra"
	mkdir -p "$extra/scripts/local-top"

	cp "local-top/rootlayered" "$extra/scripts/local-top/rootlayered"
	chmod +x "$extra/scripts/local-top/rootlayered"

	cat > "$extra/scripts/local-top/ORDER" <<'EOF'
/scripts/local-top/cryptopensc "$@"
[ -e /conf/param.conf ] && . /conf/param.conf
/scripts/local-top/iscsi "$@"
[ -e /conf/param.conf ] && . /conf/param.conf
/scripts/local-top/rootlayered "$@"
[ -e /conf/param.conf ] && . /conf/param.conf
/scripts/local-top/rooturl "$@"
[ -e /conf/param.conf ] && . /conf/param.conf
/scripts/local-top/cryptroot "$@"
[ -e /conf/param.conf ] && . /conf/param.conf
EOF

	info "Building extra cpio"
	(cd "$extra" && find . | cpio -o -H newc | gzip > "${WORK_DIR}/rootlayered.cpio.gz")

	info "Concatenating with maas boot-initrd"
	cat "${MAAS_DIR}/boot-initrd" "${WORK_DIR}/rootlayered.cpio.gz" > "${WORK_DIR}/combined-initrd.img"
}

run_qemu() {
	local layer_urls="" i
	for i in "${!RESOLVED_LAYERS[@]}"; do
		layer_urls="${layer_urls},http://10.0.2.2:${HTTP_PORT}/layer${i}.squashfs"
	done
	local root_param="overlayfs:http://10.0.2.2:${HTTP_PORT}/upper.squashfs${layer_urls}"

	local extra_cmdline=""
	$INTERACTIVE && extra_cmdline=" break=top"

	info "Booting QEMU (root=${root_param})"
	$INTERACTIVE && info "Interactive: will break to a shell before local-top runs"
	info "Ctrl-A X to quit QEMU when done"

	# QEMU's -netdev user always hands out 10.0.2.15/24 via gateway
	# 10.0.2.2, so we skip dhcpcd (and its slow ARP duplicate-address
	# probe) entirely with a static ip= kernel param. Interface name
	# is explicit (ens3, as observed under this QEMU machine type/nic
	# setup) rather than left blank, since blank falls back to
	# "first available device" which is fragile once more than one
	# NIC is present, e.g. in production. Verify with `ip a` if the
	# device model, PCI topology, or ordering changes.
	local net_ifname="ens3"
	local static_ip="ip=10.0.2.15::10.0.2.2:255.255.255.0::${net_ifname}:off"

	sudo qemu-system-x86_64 \
		-enable-kvm \
		-cpu host \
		-smp 4 \
		-m 4096 \
		-netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
		-kernel "${MAAS_DIR}/boot-kernel" \
		-initrd "${WORK_DIR}/combined-initrd.img" \
		-append "root=${root_param} console=ttyS0 overlayroot=tmpfs ${static_ip}${extra_cmdline}" \
		-nographic
}

usage() {
	cat <<EOF
Usage: ${0##*/} [-i|--interactive] [--source LAYERS]

  -i, --interactive     Break to a debug shell (break=top) before
                         local-top scripts run, so you can manually
                         invoke /scripts/local-top/rootlayered yourself.
                         Type 'exit' in that shell to continue booting.
  --source LAYERS        Comma-separated list of squashfs layers,
                         stacked in the order given (default: cloud).
                         Each entry is one of:
                           maas    - maas.io ephemeral squashfs
                           cloud   - Ubuntu server cloud image squashfs
                           /path/to/foo.squashfs - your own squashfs
                         Example: --source maas,/tmp/mine.squashfs
EOF
}

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
			-i|--interactive) INTERACTIVE=true; shift ;;
			--source) SOURCE="$2"; shift 2 ;;
			-h|--help) usage; exit 0 ;;
			*) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 1 ;;
		esac
	done
}

main() {
	parse_args "$@"
	check_deps || exit 1
	mkdir -p "${WORK_DIR}"
	info "Squashfs source: ${SOURCE}"

	download_maas_kernel_initrd || exit 1
	resolve_sources || exit 1
	build_upper_squashfs || exit 1
	setup_httpd_root
	start_httpd
	trap stop_httpd EXIT

	build_combined_initrd || exit 1
	run_qemu
}

main "$@"
