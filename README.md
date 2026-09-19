# cloud-initramfs-rootlayered
`rootlayered` is an initramfs module that allows you to download images to tmpfs or use local ones via `file://`. It stacks them via overlayfs and uses the result as root.

## Example Usage
Append this to your kernel cmdline.
 `root=overlayfs:http://example.com/layer1.squashfs,http://example.com/layer2.squashfs`

## Rationale

Canonical ships their rootfs images as squashfs on the Live ISO, MAAS image store and cloud image store. Using squashfs and overlayfs you can create "delta" squashfs images that conveniently allow to alter the result of an existing image without having to use packers, and allow for small local shipping.

Existing tools like `rooturl` allow to load squashfs over the network, but not stack in overlayfs, leaving the "delta"-mechanic unsupported.

With `cloud-initramfs-rootlayered` we can load squashfs images and deltas over the network or local and stack them as rootfs for use in e.g. PXE boot etc. 

## Build
Just run `make`. Otherwise, you can also attach the hookscripts to an existing initramfs using the `mkcip.sh` script.

## Conflict with [cloud-initramfs-tools](https://github.com/beagleboard/cloud-initramfs-tools/tree/master) rooturl

Canonical MAAS' initrd contains [cloud-initramfs-tools](https://github.com/beagleboard/cloud-initramfs-tools/tree/master), which triggers on any `root=*:http://*`. This is conflicting with our scheme.

The dpkg package informs about the clash, but in any case we remove `rooturl` from the running scripts.

## Future Work

Expand to use other archive types, NFS etc. 
___

Claude helped me to package this project, but the work is fully my own.
