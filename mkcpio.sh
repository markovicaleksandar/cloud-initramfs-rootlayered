#!/bin/bash
#  Stack the rootlayered local-top script onto an existing initrd.
#  Copyright, 2024 Aleksandar Markovic
#
#  Reads a base initrd, appends a cpio segment carrying
#  scripts/local-top/rootlayered plus a patched ORDER file, and
#  writes the combined image to stdout.
#
#  Usage: ./mkcpio.sh BASE_INITRD > combined-initrd.img

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_DIR="${SCRIPT_DIR}/.tmp"
EXTRA_DIR="${TMP_DIR}/extra"

# stdout carries the image, so all messages go to stderr
info() { echo ">> $*" >&2; }

usage() {
	cat >&2 <<EOF
Usage: ${0##*/} BASE_INITRD > combined-initrd.img

  BASE_INITRD   Path to the initrd to stack onto.

The combined image is written to stdout; redirect it to a file.
EOF
}

main() {
	[[ $# -eq 1 ]] || { usage; exit 1; }
	case "$1" in
		-h|--help) usage; exit 0 ;;
	esac

	local base_initrd="$1"
	[[ -f "$base_initrd" ]] || {
		echo "ERROR: base initrd not found: $base_initrd" >&2
		exit 1
	}
	[[ -f "${SCRIPT_DIR}/local-top/rootlayered" ]] || {
		echo "ERROR: ${SCRIPT_DIR}/local-top/rootlayered not found" >&2
		exit 1
	}
	[[ -t 1 ]] && {
		echo "ERROR: refusing to write binary image to a terminal" >&2
		usage
		exit 1
	}

	rm -rf "$TMP_DIR"
	mkdir -p "${EXTRA_DIR}/scripts/local-top"

	cp "${SCRIPT_DIR}/local-top/rootlayered" "${EXTRA_DIR}/scripts/local-top/rootlayered"
	chmod +x "${EXTRA_DIR}/scripts/local-top/rootlayered"

	# Replacement ORDER file: same as the base image's ORDER, but with
	# rootlayered inserted before rooturl so our script gets a chance
	# to remove rooturl before it runs (avoids the ROOT= collision).
	cat > "${EXTRA_DIR}/scripts/local-top/ORDER" <<'EOF'
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

	info "Writing combined initrd to stdout"
	cat "$base_initrd"
	(cd "$EXTRA_DIR" && find . | cpio -o -H newc 2>/dev/null | gzip)
}

main "$@"
