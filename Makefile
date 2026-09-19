# Makefile for cloud-initramfs-rootlayered
# Copyright, 2024 Aleksandar Markovic

PACKAGE_NAME := cloud-initramfs-rootlayered
VERSION := 0.1
ARCH := all

DEB_FILE := $(PACKAGE_NAME)_$(VERSION)_$(ARCH).deb
BUILD_DIR := build/$(PACKAGE_NAME)_$(VERSION)

.PHONY: all clean install

all: $(DEB_FILE)

$(DEB_FILE): hooks/rootlayered local-top/rootlayered prepare-build.sh
	@./prepare-build.sh
	@echo "Building package..."
	@dpkg-deb --build $(BUILD_DIR) $(DEB_FILE)
	@echo ""
	@echo "Package built successfully: $(DEB_FILE)"
	@echo ""
	@echo "To install:"
	@echo "  sudo dpkg -i $(DEB_FILE)"
	@echo ""
	@echo "To use, add to kernel command line:"
	@echo "  root=overlayfs:http://example.com/layer1.squashfs,http://example.com/layer2.squashfs"

clean:
	@rm -rf build
	@rm -f $(DEB_FILE)
	@echo "Cleaned build artifacts"

install: $(DEB_FILE)
	@echo "Installing $(DEB_FILE)..."
	@sudo dpkg -i $(DEB_FILE)
