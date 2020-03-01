#!/bin/bash

set -e -u

script_path=$(readlink -f ${0%/*})
version_file="${script_path}/VERSION"
arch_file="${script_path}/ARCHITECTURE"

iso_name=systemrescuecd
iso_version="$(<${version_file})"
iso_mainver="${iso_version%-*}"
iso_label="SYSRCD${iso_mainver//.}"
iso_publisher="SystemRescueCd <http://www.system-rescue-cd.org>"
iso_application="SystemRescueCd"
install_dir=sysresccd
work_dir=work
out_dir=out
gpg_key=
arch="$(<${arch_file})"
sfs_comp="xz"
sfs_opts="-Xbcj x86 -b 512k -Xdict-size 512k"

verbose=""

umask 0022

_usage ()
{
    echo "usage ${0} [options]"
    echo
    echo " General options:"
    echo "    -N <iso_name>      Set an iso filename (prefix)"
    echo "                        Default: ${iso_name}"
    echo "    -V <iso_version>   Set an iso version (in filename)"
    echo "                        Default: ${iso_version}"
    echo "    -L <iso_label>     Set an iso label (disk label)"
    echo "                        Default: ${iso_label}"
    echo "    -P <publisher>     Set a publisher for the disk"
    echo "                        Default: '${iso_publisher}'"
    echo "    -A <application>   Set an application name for the disk"
    echo "                        Default: '${iso_application}'"
    echo "    -D <install_dir>   Set an install_dir (directory inside iso)"
    echo "                        Default: ${install_dir}"
    echo "    -w <work_dir>      Set the working directory"
    echo "                        Default: ${work_dir}"
    echo "    -o <out_dir>       Set the output directory"
    echo "                        Default: ${out_dir}"
    echo "    -v                 Enable verbose output"
    echo "    -h                 This help message"
    exit ${1}
}

# Helper function to run make_*() only one time per architecture.
run_once() {
    if [[ ! -e ${work_dir}/build.${1} ]]; then
        $1
        touch ${work_dir}/build.${1}
    fi
}

# Setup custom pacman.conf with current cache directories.
make_pacman_conf() {
    local _cache_dirs
    _cache_dirs=($(pacman -v 2>&1 | grep '^Cache Dirs:' | sed 's/Cache Dirs:\s*//g'))
    sed -r "s|^#?\\s*CacheDir.+|CacheDir = $(echo -n ${_cache_dirs[@]})|g" ${script_path}/pacman.conf > ${work_dir}/pacman.conf
}

# Base installation, plus needed packages (airootfs)
make_basefs() {
    setarch ${arch} mkarchiso ${verbose} -w "${work_dir}/${arch}" -C "${work_dir}/pacman.conf" -D "${install_dir}" init
    setarch ${arch} mkarchiso ${verbose} -w "${work_dir}/${arch}" -C "${work_dir}/pacman.conf" -D "${install_dir}" -p "haveged intel-ucode amd-ucode memtest86+ mkinitcpio-nfs-utils nbd zsh efitools" install
}

# Additional packages (airootfs)
make_packages() {
    setarch ${arch} mkarchiso ${verbose} -w "${work_dir}/${arch}" -C "${work_dir}/pacman.conf" -D "${install_dir}" -p "$(grep -h -v '^#' ${script_path}/packages)" install
}

# Copy mkinitcpio archiso hooks and build initramfs (airootfs)
make_setup_mkinitcpio() {
    local _hook
    mkdir -p ${work_dir}/${arch}/airootfs/etc/initcpio/hooks
    mkdir -p ${work_dir}/${arch}/airootfs/etc/initcpio/install
    for _hook in archiso archiso_shutdown archiso_pxe_common archiso_pxe_nbd archiso_pxe_http archiso_pxe_nfs archiso_loop_mnt; do
        cp /usr/lib/initcpio/hooks/${_hook} ${work_dir}/${arch}/airootfs/etc/initcpio/hooks
        cp /usr/lib/initcpio/install/${_hook} ${work_dir}/${arch}/airootfs/etc/initcpio/install
    done
    sed -i "s|/usr/lib/initcpio/|/etc/initcpio/|g" ${work_dir}/${arch}/airootfs/etc/initcpio/install/archiso_shutdown
    cp /usr/lib/initcpio/install/archiso_kms ${work_dir}/${arch}/airootfs/etc/initcpio/install
    cp /usr/lib/initcpio/archiso_shutdown ${work_dir}/${arch}/airootfs/etc/initcpio
    cp ${script_path}/mkinitcpio.conf ${work_dir}/${arch}/airootfs/etc/mkinitcpio-archiso.conf
    gnupg_fd=
    if [[ ${gpg_key} ]]; then
      gpg --export ${gpg_key} >${work_dir}/gpgkey
      exec 17<>${work_dir}/gpgkey
    fi

    mkdir -p ${work_dir}/${arch}/airootfs/etc/modprobe.d
    cp ${script_path}/airootfs/etc/modprobe.d/* ${work_dir}/${arch}/airootfs/etc/modprobe.d/

    ARCHISO_GNUPG_FD=${gpg_key:+17} setarch ${arch} mkarchiso ${verbose} -w "${work_dir}/${arch}" -C "${work_dir}/pacman.conf" -D "${install_dir}" -r 'mkinitcpio -c /etc/mkinitcpio-archiso.conf -k /boot/vmlinuz-linux-lts -g /boot/sysresccd.img' run
    if [[ ${gpg_key} ]]; then
      exec 17<&-
    fi
}

# Customize installation (airootfs)
make_customize_airootfs() {
    cp -af --no-preserve=ownership ${script_path}/airootfs ${work_dir}/${arch}

    cp ${script_path}/pacman.conf ${work_dir}/${arch}/airootfs/etc

    cp ${version_file} ${work_dir}/${arch}/airootfs/root/version

    sed "s|%ARCHISO_LABEL%|${iso_label}|g;
         s|%ISO_VERSION%|${iso_version}|g;
         s|%ISO_ARCH%|${arch}|g;
         s|%INSTALL_DIR%|${install_dir}|g" \
         ${script_path}/airootfs/usr/bin/bashlogin > ${work_dir}/${arch}/airootfs/usr/bin/bashlogin

    curl -o ${work_dir}/${arch}/airootfs/etc/pacman.d/mirrorlist 'https://www.archlinux.org/mirrorlist/?country=all&protocol=http&use_mirror_status=on'

    setarch ${arch} mkarchiso ${verbose} -w "${work_dir}/${arch}" -C "${work_dir}/pacman.conf" -D "${install_dir}" -r '/root/customize_airootfs.sh' run
    rm ${work_dir}/${arch}/airootfs/root/customize_airootfs.sh
}

# Prepare kernel/initramfs ${install_dir}/boot/
make_boot() {
    mkdir -p ${work_dir}/iso/${install_dir}/boot/${arch}
    cp ${work_dir}/${arch}/airootfs/boot/sysresccd.img ${work_dir}/iso/${install_dir}/boot/${arch}/sysresccd.img
    cp ${work_dir}/${arch}/airootfs/boot/vmlinuz-linux-lts ${work_dir}/iso/${install_dir}/boot/${arch}/vmlinuz
}

# Add other aditional/extra files to ${install_dir}/boot/
make_boot_extra() {
    cp ${work_dir}/${arch}/airootfs/boot/memtest86+/memtest.bin ${work_dir}/iso/${install_dir}/boot/memtest
    cp ${work_dir}/${arch}/airootfs/usr/share/licenses/common/GPL2/license.txt ${work_dir}/iso/${install_dir}/boot/memtest.COPYING
    cp ${work_dir}/${arch}/airootfs/boot/intel-ucode.img ${work_dir}/iso/${install_dir}/boot/intel_ucode.img
    cp ${work_dir}/${arch}/airootfs/usr/share/licenses/intel-ucode/LICENSE ${work_dir}/iso/${install_dir}/boot/intel_ucode.LICENSE
    cp ${work_dir}/${arch}/airootfs/boot/amd-ucode.img ${work_dir}/iso/${install_dir}/boot/amd_ucode.img
    cp ${work_dir}/${arch}/airootfs/usr/share/licenses/amd-ucode/LICENSE ${work_dir}/iso/${install_dir}/boot/amd_ucode.LICENSE
}

# Prepare /${install_dir}/boot/syslinux
make_syslinux() {
    _uname_r=$(file -b ${work_dir}/${arch}/airootfs/boot/vmlinuz-linux-lts| awk 'f{print;f=0} /version/{f=1}' RS=' ')
    mkdir -p ${work_dir}/iso/${install_dir}/boot/syslinux
    for _cfg in ${script_path}/syslinux/*.cfg; do
        sed "s|%ARCHISO_LABEL%|${iso_label}|g;
             s|%ISO_VERSION%|${iso_version}|g;
             s|%ISO_ARCH%|${arch}|g;
             s|%INSTALL_DIR%|${install_dir}|g" ${_cfg} > ${work_dir}/iso/${install_dir}/boot/syslinux/${_cfg##*/}
    done
    cp ${work_dir}/${arch}/airootfs/usr/lib/syslinux/bios/*.c32 ${work_dir}/iso/${install_dir}/boot/syslinux
    cp ${work_dir}/${arch}/airootfs/usr/lib/syslinux/bios/lpxelinux.0 ${work_dir}/iso/${install_dir}/boot/syslinux
    cp ${work_dir}/${arch}/airootfs/usr/lib/syslinux/bios/memdisk ${work_dir}/iso/${install_dir}/boot/syslinux
    mkdir -p ${work_dir}/iso/${install_dir}/boot/syslinux/hdt
    gzip -c -9 ${work_dir}/${arch}/airootfs/usr/share/hwdata/pci.ids > ${work_dir}/iso/${install_dir}/boot/syslinux/hdt/pciids.gz
    gzip -c -9 ${work_dir}/${arch}/airootfs/usr/lib/modules/${_uname_r}/modules.alias > ${work_dir}/iso/${install_dir}/boot/syslinux/hdt/modalias.gz
}

# Prepare /isolinux
make_isolinux() {
    mkdir -p ${work_dir}/iso/isolinux
    sed "s|%INSTALL_DIR%|${install_dir}|g" ${script_path}/isolinux/isolinux.cfg > ${work_dir}/iso/isolinux/isolinux.cfg
    cp ${work_dir}/${arch}/airootfs/usr/lib/syslinux/bios/isolinux.bin ${work_dir}/iso/isolinux/
    cp ${work_dir}/${arch}/airootfs/usr/lib/syslinux/bios/isohdpfx.bin ${work_dir}/iso/isolinux/
    cp ${work_dir}/${arch}/airootfs/usr/lib/syslinux/bios/ldlinux.c32 ${work_dir}/iso/isolinux/
}

# Prepare /EFI
make_efi() {
    rm -rf ${work_dir}/iso/EFI
    rm -rf ${work_dir}/iso/boot
    mkdir -p ${work_dir}/iso/EFI/boot
    mkdir -p ${work_dir}/iso/boot/grub
    cp -a /usr/lib/grub/x86_64-efi ${work_dir}/iso/boot/grub/
    cp ${script_path}/efiboot/grub/font.pf2 ${work_dir}/iso/boot/grub/
    sed "s|%ARCHISO_LABEL%|${iso_label}|g;
         s|%ISO_VERSION%|${iso_version}|g;
         s|%ISO_ARCH%|${arch}|g;
         s|%INSTALL_DIR%|${install_dir}|g" \
         ${script_path}/efiboot/grub/grubsrcd.cfg > ${work_dir}/iso/boot/grub/grubsrcd.cfg
}

# Prepare efiboot.img::/EFI for "El Torito" EFI boot mode
make_efiboot() {

    rm -rf ${work_dir}/memdisk
    mkdir -p "${work_dir}/memdisk"
    mkdir -p "${work_dir}/memdisk/boot/grub"
    cp -a ${script_path}/efiboot/grub/grubinit.cfg "${work_dir}/memdisk/boot/grub/grub.cfg"
    tar -c -C "${work_dir}/memdisk" -f ${work_dir}/memdisk.img boot

    rm -rf ${work_dir}/efitemp
    mkdir -p ${work_dir}/efitemp/efi/boot

    grub-mkimage -m "${work_dir}/memdisk.img" -o "${work_dir}/iso/EFI/boot/bootx64.efi" \
    	--prefix='(memdisk)/boot/grub' -d /usr/lib64/grub/x86_64-efi -C xz -O x86_64-efi \
    	search iso9660 configfile normal memdisk tar boot linux part_msdos part_gpt \
    	part_apple configfile help loadenv ls reboot chain search_fs_uuid multiboot \
    	fat iso9660 udf ext2 btrfs ntfs reiserfs xfs lvm ata

    cp -a "${work_dir}/iso/EFI/boot/bootx64.efi" "${work_dir}/efitemp/efi/boot/bootx64.efi"

    mkdir -p ${work_dir}/iso/EFI/archiso
    rm -f "${work_dir}/iso/EFI/archiso/efiboot.img"
    mformat -C -f 1440 -L 16 -i "${work_dir}/iso/EFI/archiso/efiboot.img" ::
    mcopy -s -i "${work_dir}/iso/EFI/archiso/efiboot.img" "${work_dir}/efitemp/efi" ::/
}

# Build airootfs filesystem image
make_prepare() {
    cp -a -l -f ${work_dir}/${arch}/airootfs ${work_dir}
    setarch ${arch} mkarchiso ${verbose} -w "${work_dir}" -D "${install_dir}" pkglist
    setarch ${arch} mkarchiso ${verbose} -w "${work_dir}" -D "${install_dir}" ${gpg_key:+-g ${gpg_key}} -c ${sfs_comp} -t "${sfs_opts}" prepare
    rm -rf ${work_dir}/airootfs
    # rm -rf ${work_dir}/${arch}/airootfs (if low space, this helps)
}

# Build ISO
make_iso() {
    cp ${version_file} ${work_dir}/iso/${install_dir}/
    setarch ${arch} mkarchiso ${verbose} -w "${work_dir}" -D "${install_dir}" -L "${iso_label}" -P "${iso_publisher}" -A "${iso_application}" -o "${out_dir}" iso "${iso_name}-${arch}-${iso_version}.iso"
}

if [[ ${EUID} -ne 0 ]]; then
    echo "This script must be run as root."
    _usage 1
fi

while getopts 'N:V:L:P:A:D:w:o:g:vh' arg; do
    case "${arg}" in
        N) iso_name="${OPTARG}" ;;
        V) iso_version="${OPTARG}" ;;
        L) iso_label="${OPTARG}" ;;
        P) iso_publisher="${OPTARG}" ;;
        A) iso_application="${OPTARG}" ;;
        D) install_dir="${OPTARG}" ;;
        w) work_dir="${OPTARG}" ;;
        o) out_dir="${OPTARG}" ;;
        g) gpg_key="${OPTARG}" ;;
        v) verbose="-v" ;;
        h) _usage 0 ;;
        *)
           echo "Invalid argument '${arg}'"
           _usage 1
           ;;
    esac
done

mkdir -p ${work_dir}

run_once make_pacman_conf
run_once make_basefs
run_once make_packages
run_once make_setup_mkinitcpio
run_once make_customize_airootfs
run_once make_boot
run_once make_boot_extra
run_once make_syslinux
run_once make_isolinux
run_once make_efi
run_once make_efiboot
run_once make_prepare
run_once make_iso
