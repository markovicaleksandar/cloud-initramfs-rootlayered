#!/bin/bash
#  Build preparation script for cloud-initramfs-rootlayered package
#  Copyright, 2024 Aleksandar Markovic

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PACKAGE_NAME="cloud-initramfs-rootlayered"
VERSION="0.1"
ARCH="all"
MAINTAINER="Aleksandar Markovic"
DESCRIPTION="Initramfs boot with overlayfs-layered root from HTTP and local"

BUILD_DIR="${SCRIPT_DIR}/build/${PACKAGE_NAME}_${VERSION}"
DEB_DIR="${BUILD_DIR}/DEBIAN"
HOOKS_DIR="${BUILD_DIR}/usr/share/initramfs-tools/hooks"
SCRIPTS_DIR="${BUILD_DIR}/usr/share/initramfs-tools/scripts/local-top"

echo "Preparing build directory structure..."

# Create directory structure
mkdir -p "${DEB_DIR}"
mkdir -p "${HOOKS_DIR}"
mkdir -p "${SCRIPTS_DIR}"

# Copy files
cp "${SCRIPT_DIR}/hooks/rootlayered" "${HOOKS_DIR}/rootlayered"
cp "${SCRIPT_DIR}/local-top/rootlayered" "${SCRIPTS_DIR}/rootlayered"

# Set permissions
chmod 755 "${HOOKS_DIR}/rootlayered"
chmod 755 "${SCRIPTS_DIR}/rootlayered"

# Create control file
cat > "${DEB_DIR}/control" <<EOF
Package: ${PACKAGE_NAME}
Version: ${VERSION}
Section: admin
Priority: optional
Architecture: ${ARCH}
Depends: initramfs-tools, wget
Conflicts: cloud-initramfs-rooturl
Replaces: cloud-initramfs-rooturl
Maintainer: ${MAINTAINER}
Description: ${DESCRIPTION}
 This package provides initramfs support for booting with an overlayfs-based
 layered root filesystem loaded from HTTP URLs and also local via file://. It allows specifying multiple squashfs images that are mounted as overlay layers to form the root filesystem.
 .
 The boot parameter format is:
 root=overlayfs:http://example.com/upper.squashfs,http://example.com/lower.squashfs
EOF

# Create postinst script
cat > "${DEB_DIR}/postinst" <<'EOF'
#!/bin/sh
set -e

case "$1" in
    configure|reconfigure)
        update-initramfs -u
        ;;
esac

exit 0
EOF
chmod 755 "${DEB_DIR}/postinst"

# Create postrm script
cat > "${DEB_DIR}/postrm" <<'EOF'
#!/bin/sh
set -e

case "$1" in
    remove|purge)
        update-initramfs -u
        ;;
esac

exit 0
EOF
chmod 755 "${DEB_DIR}/postrm"

echo "Build preparation complete"
