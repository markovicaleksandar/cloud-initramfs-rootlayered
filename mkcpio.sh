#!/bin/bash
#  Stack the rootlayered local-top script onto an existing initrd.
#  Copyright, 2024 Aleksandar Markovic
#
#  Reads a base initrd and writes a combined image to stdout, made of:
#
#    1. the base initrd, unchanged
#    2. optional --include files, as an UNCOMPRESSED cpio segment
#       (4-byte aligned; see note below)
#    3. scripts/local-top/rootlayered plus a patched ORDER file,
#       as a gzipped cpio segment
#
#  Included files land at the initramfs root, so a file added as
#  --include /path/to/foo.squashfs is reachable as file:///foo.squashfs
#  and needs no download at boot.
#
#  Alignment: the kernel only accepts an uncompressed cpio member that
#  starts on a 4-byte boundary, so segment 2 is padded with zeros to
#  reach one. Compressed members have no such requirement, which is why
#  segment 3 can follow unaligned. Segment 2 comes before segment 3 so
#  the padding is computed against the base initrd's known size rather
#  than a running offset through the stream.
#
#  Usage: ./mkcpio.sh [--include FILE]... BASE_INITRD > combined-initrd.img

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_DIR="${SCRIPT_DIR}/.tmp"
EXTRA_DIR="${TMP_DIR}/extra"
INCLUDE_DIR="${TMP_DIR}/include"

INCLUDES=()

# stdout carries the image, so all messages go to stderr
info() { echo ">> $*" >&2; }

usage() {
	cat >&2 <<EOF
Usage: ${0##*/} [--include FILE]... BASE_INITRD > combined-initrd.img

  BASE_INITRD        Path to the initrd to stack onto.
  -I, --include FILE Add FILE to the initramfs root, uncompressed.
                     Repeatable. Reachable at boot as file:///<basename>.

The combined image is written to stdout; redirect it to a file.

Example:
  ${0##*/} --include base.squashfs boot-initrd > combined-initrd.img
  ... then boot with root=overlayfs:file:///base.squashfs
EOF
}

# Stage included files into one directory so a single cpio run picks
# them all up at the archive root. Hardlink where possible to avoid
# copying large images; fall back to a copy across filesystems.
stage_includes() {
	local f name
	mkdir -p "$INCLUDE_DIR"
	for f in "${INCLUDES[@]}"; do
		[[ -f "$f" ]] || {
			echo "ERROR: include file not found: $f" >&2
			return 1
		}
		name="$(basename "$f")"
		ln "$f" "${INCLUDE_DIR}/${name}" 2>/dev/null \
			|| cp "$f" "${INCLUDE_DIR}/${name}"
		info "Including /${name}  (file:///${name})"
	done
}

stage_extra() {
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
}

parse_args() {
	local positional=()
	while [[ $# -gt 0 ]]; do
		case "$1" in
			-I|--include) INCLUDES+=("$2"); shift 2 ;;
			-h|--help) usage; exit 0 ;;
			-*) echo "ERROR: unknown option: $1" >&2; usage; exit 1 ;;
			*) positional+=("$1"); shift ;;
		esac
	done

	[[ ${#positional[@]} -eq 1 ]] || { usage; exit 1; }
	BASE_INITRD="${positional[0]}"
}

main() {
	parse_args "$@"

	[[ -f "$BASE_INITRD" ]] || {
		echo "ERROR: base initrd not found: $BASE_INITRD" >&2
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
	stage_extra
	[[ ${#INCLUDES[@]} -gt 0 ]] && stage_includes

	info "Writing combined initrd to stdout"

	cat "$BASE_INITRD"

	if [[ ${#INCLUDES[@]} -gt 0 ]]; then
		local base_size pad
		base_size=$(stat -c %s "$BASE_INITRD")
		pad=$(( (4 - base_size % 4) % 4 ))
		info "Padding ${pad} byte(s) to 4-byte align the uncompressed segment"
		(( pad > 0 )) && head -c "$pad" /dev/zero
		(cd "$INCLUDE_DIR" && find . | cpio -o -H newc --quiet)
	fi

	(cd "$EXTRA_DIR" && find . | cpio -o -H newc --quiet | gzip)
}

main "$@"