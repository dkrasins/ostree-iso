# /usr/bin/bash
set -x
set -e

VOLID=OCK
ISO_FILE="ock.iso"

IGNITION_PATH=config.ign

# important iso paths
ISO_DIR=./iso
IMAGES_DIR="${ISO_DIR}/images/pxeboot"
ISOLINUX_DIR="${ISO_DIR}/isolinux"
KERNEL_PATH="${IMAGES_DIR}/vmlinuz"
INITRD_PATH="${IMAGES_DIR}/initrd.img"
ISOLINUX_PATH="${ISOLINUX_DIR}/isolinux.bin"
LDLINUX_PATH="${ISOLINUX_DIR}/ldlinux.c32"
LIBCOM_PATH="${ISOLINUX_DIR}/libcom32.c32"
LIBUTIL_PATH="${ISOLINUX_DIR}/libutil.c32"
VESAMENU_PATH="${ISOLINUX_DIR}/vesamenu.c32"
ISOLINUX_CFG_PATH="${ISOLINUX_DIR}/isolinux.cfg"
ISOLINUX_KERNEL_PATH="${ISOLINUX_DIR}/vmlinuz"
ISOLINUX_INITRD_PATH="${ISOLINUX_DIR}/initrd.img"
BOOT_FILES_DIR="${ISO_DIR}/EFI/BOOT"

SYSLINUX_DIR="/usr/share/syslinux"
LOCAL_ISOLINUX_PATH="${SYSLINUX_DIR}/isolinux.bin"
LOCAL_LDLINUX_PATH="${SYSLINUX_DIR}/ldlinux.c32"
LOCAL_LIBCOM_PATH="${SYSLINUX_DIR}/libcom32.c32"
LOCAL_LIBUTIL_PATH="${SYSLINUX_DIR}/libutil.c32"
LOCAL_VESAMENU_PATH="${SYSLINUX_DIR}/vesamenu.c32"

# ostree stuff
TREE=ostree
REPO="$TREE/repo"
TRANSPORT=docker://
REGISTRY=container-registry.oracle.com/olcne/ock-ostree
TAG=1.32

# container stuff
ARCHIVE_TRANSPORT="oci-archive:"
ARCHIVE_PATH="${ISO_DIR}/ostree.tar"
CONTAINER_NAME=ocneiso
CONTAINER_BOOT_FILES_DIR="usr/lib/ostree-boot/efi/EFI"

copy_to() {
	local FROM="$1"
	local TO="$2"

	DIR=$(dirname "$TO")
	mkdir -p "${DIR}"
	cp "$FROM" "$TO"
}

LINKER=
resolve_linker() {
	if [ -n "$LINKER" ]; then
		echo "$LINKER"
	fi

	LINKER=$(find "$1/usr/lib64" -iname 'ld-linux-*')
	if [ -z "$LINKER" ]; then
		echo "Could not find runtime linker for container"
		exit 1
	fi

	echo "$LINKER"
}

resolve_dependencies() {
	local FILE="$1"
	local ALT_ROOT="$2"

	LNK=$(resolve_linker "$ALT_ROOT")

	ALT_LD_LIBRARY_PATH="$ALT_ROOT/usr/lib64"
	LIBS=$(LD_LIBRARY_PATH="$ALT_LD_LIBRARY_PATH" $LNK --list "${ALT_ROOT}${FILE}" | grep ' => ' | cut -d' ' -f3)
	for lib in $LIBS; do
		echo ${lib#"$ALT_ROOT"}
	done
}

copy_with_deps() {
	local FILE="$1"
	local ALT_ROOT="$2"
	local NEW_ROOT="$3"

	local DEPS=$(resolve_dependencies "$FILE" "$ALT_ROOT")
	for dep in $DEPS; do
		cp "${ALT_ROOT}${dep}" "${NEW_ROOT}${dep}"
	done
}

ARCHIVE_DIR=$(dirname "$ARCHIVE_PATH")
mkdir -p "$ARCHIVE_DIR"

# Get the ostree archive as an oci archive that can be
# embedded into the iso.
if [ ! -f "$ARCHIVE_PATH" ]; then
	skopeo copy "${TRANSPORT}${REGISTRY}:${TAG}" "${ARCHIVE_TRANSPORT}${ARCHIVE_PATH}"
fi

# Fetch an initramfs and a kernel
podman container exists "$CONTAINER_NAME" || podman create --name "$CONTAINER_NAME" "${ARCHIVE_TRANSPORT}${ARCHIVE_PATH}"


# Get all the necessary files for the iso
ROOT=$(podman container mount "$CONTAINER_NAME")
KERNEL_DIR="$ROOT/usr/lib/modules"
CONTAINER_KERNEL_PATH=$(find "$KERNEL_DIR" -type f -iname vmlinuz)
CONTAINER_INITRD_PATH=$(find "$KERNEL_DIR" -type f -iname initramfs.img)

copy_to "$CONTAINER_KERNEL_PATH" "$KERNEL_PATH"
copy_to "$CONTAINER_KERNEL_PATH" "$ISOLINUX_KERNEL_PATH"
copy_to "$LOCAL_ISOLINUX_PATH" "$ISOLINUX_PATH"
copy_to "$LOCAL_LIBCOM_PATH" "$LIBCOM_PATH"
copy_to "$LOCAL_LIBUTIL_PATH" "$LIBUTIL_PATH"
copy_to "$LOCAL_VESAMENU_PATH" "$VESAMENU_PATH"
copy_to "$LOCAL_LDLINUX_PATH" "$LDLINUX_PATH"

for f in $(find "${ROOT}/${CONTAINER_BOOT_FILES_DIR}" -type f); do
	filename=$(basename "$f")
	copy_to "$f" "${BOOT_FILES_DIR}/$filename"
done


# Add stuff to the initramfs
# - disable extra services that assume the rootfs is actually going to be used
# - add new services to install the ostree from the disk
# - add an ingition config to be used by the installed system
TMP_INITRD_FIRMWARE_DIR="./initrd-early"
mkdir -p "${TMP_INITRD_FIRMWARE_DIR}"
pushd "${TMP_INITRD_FIRMWARE_DIR}"
lsinitrd --unpackearly "$CONTAINER_INITRD_PATH"
popd # TMP_INITRD_FIRMWARE_DIR

TMP_INITRD_DIR="./initrd-scratch"
mkdir -p "${TMP_INITRD_DIR}"
pushd "${TMP_INITRD_DIR}"
lsinitrd --unpack "$CONTAINER_INITRD_PATH"
popd # TMP_INITRD_DIR

# The depenencies for a couple programs need to get resolved.  That involes
# traipsing around the container using its runtime linker and libraries.
# This gets a bit silly
copy_with_deps /usr/bin/skopeo "$ROOT" "$TMP_INITRD_DIR"
copy_with_deps /usr/bin/ostree "$ROOT" "$TMP_INITRD_DIR"
copy_with_deps /usr/bin/rpm-ostree "$ROOT" "$TMP_INITRD_DIR"

# Add the service that sits between the partitioning step and the
# file processing that deploys the ostree.
INITRAMFS_EXTRA="./initramfs-content"
cp -r $INITRAMFS_EXTRA/* "$TMP_INITRD_DIR"

# Add the ignition content
cp "$IGNITION_PATH" "${TMP_INITRD_DIR}/config.ign"

# Package the initramfs sections into a complete initramfs.  Create an
# empty initramfs file so that an absolute path can be found and any
# directory changes can be ignored
touch $INITRD_PATH
INITRD_PATH=$(realpath $INITRD_PATH)

pushd "$TMP_INITRD_FIRMWARE_DIR"
find . -depth -print | cpio -oc > "$INITRD_PATH"
popd # TMP_INITRD_FIRMWARE_DIR

pushd "$TMP_INITRD_DIR"
find . -depth -print | cpio -oc | gzip -c >> "$INITRD_PATH"
popd # TMP_INITRD_DIR

cp "$INITRD_PATH" "$ISOLINUX_INITRD_PATH"

# Set up all the boot configuration
EFI_GRUB_CFG="${BOOT_FILES_DIR}/grub.cfg"
EFI_BOOT_CFG="${BOOT_FILES_DIR}/BOOT.conf"
cat > "$EFI_GRUB_CFG" << EOF
set default="1"

function load_video {
  insmod efi_gop
  insmod efi_uga
  insmod video_bochs
  insmod video_cirrus
  insmod all_video
}

load_video
set gfxpayload=keep
insmod gzio
insmod part_gpt
insmod ext2

set timeout=30
### END /etc/grub.d/00_header ###

search --no-floppy --set=root -l 'OCK'

### BEGIN /etc/grub.d/10_linux ###
menuentry 'Install Oracle Container Host for Kubernetes' --class fedora --class gnu-linux --class gnu --class os {
	linuxefi /images/pxeboot/vmlinuz rw ip=dhcp rd.neednet=1 ignition.platform.id=file ignition.firstboot=1 systemd.firstboot=off rd.timeout=120
	initrdefi /images/pxeboot/initrd.img
}
EOF

cp "$EFI_GRUB_CFG" "$EFI_BOOT_CFG"

cat > "$ISOLINUX_CFG_PATH" << EOF
default vesamenu.c32
timeout 600

display boot.msg

# Clear the screen when exiting the menu, instead of leaving the menu displayed.
# For vesamenu, this means the graphical background is still displayed without
# the menu itself for as long as the screen remains in graphics mode.
menu clear
menu title Oracle Linux 8.10.0
menu vshift 8
menu rows 18
menu margin 8
#menu hidden
menu helpmsgrow 15
menu tabmsgrow 13

# Border Area
menu color border * #00000000 #00000000 none

# Selected item
menu color sel 0 #ffffffff #00000000 none

# Title bar
menu color title 0 #ff7ba3d0 #00000000 none

# Press [Tab] message
menu color tabmsg 0 #ff3a6496 #00000000 none

# Unselected menu item
menu color unsel 0 #84b8ffff #00000000 none

# Selected hotkey
menu color hotsel 0 #84b8ffff #00000000 none

# Unselected hotkey
menu color hotkey 0 #ffffffff #00000000 none

# Help text
menu color help 0 #ffffffff #00000000 none

# A scrollbar of some type? Not sure.
menu color scrollbar 0 #ffffffff #ff355594 none

# Timeout msg
menu color timeout 0 #ffffffff #00000000 none
menu color timeout_msg 0 #ffffffff #00000000 none

# Command prompt text
menu color cmdmark 0 #84b8ffff #00000000 none
menu color cmdline 0 #ffffffff #00000000 none

# Do not display the actual menu unless the user presses a key. All that is displayed is a timeout message.

menu tabmsg Press Tab for full configuration options on menu items.

menu separator # insert an empty line
menu separator # insert an empty line

label linux
  menu label ^Install Oracle Container Host for Kubernetes
  kernel vmlinuz
  append initrd=initrd.img rw ip=dhcp rd.neednet=1 ignition.platform.id=file ignition.firstboot=1 systemd.firstboot=off rd.timeout=120

menu end

EOF

podman rm "$CONTAINER_NAME"

# Make the ISO
mkisofs -V "$VOLID" -o "$ISO_FILE" -b isolinux/isolinux.bin -c isolinux/boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table -iso-level 3 -r -R "$ISO_DIR"
isohybrid "$ISO_FILE"
