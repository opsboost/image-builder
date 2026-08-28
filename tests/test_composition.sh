#!/usr/bin/env bash
#
# Unit tests for image composition: the slot model, boot entries,
# partition geometry and the helpers the rootfs providers rely on.
#
# These need neither root nor a disk image, so they run on any host
#
# SPDX-FileCopyrightText: Björn Busse <bj.rn@baerlin.eu>
# SPDX-License-Identifier: BSD-3-Clause
#
# The functions and composition arrays under test are sourced at run
# time, so shellcheck can not see where they are assigned
# shellcheck disable=SC2034,SC2154

setup_suite() {
    SCRIPT_UNDER_TEST="$(dirname "${BASH_SOURCE[0]}")/../image-builder"
    LIB="$(mktemp)"

    # Source the function definitions without running main
    sed '/^args=("\$@")$/,$d' "${SCRIPT_UNDER_TEST}" > "${LIB}"

    DEBUG=0
    SEND_NOTIFICATION=0

    # shellcheck disable=SC1090
    source "${LIB}"

    # Set after sourcing: the script sets log_level itself
    log_level=quiet
}

teardown_suite() {
    rm -f "${LIB}"
}

test_gentoo_composition_has_a_single_rootfs() {
    composition_load "gentoo-containeros" "arm64"

    assert_equals "1" "$(comp_count)" "gentoo-containeros has one slot"
    assert_equals "16384" "$(composition_disk_size_mib)" "disk stays 16GiB"
    assert_equals "3" "${comp_part[0]}" "its rootfs is p3"
    assert_equals "rest" "${comp_size[0]}" "its rootfs fills the disk"
    assert_equals "xfs" "${comp_fs[0]}" "its rootfs is xfs"
    assert_equals "Image-virt-arm64" "${comp_kernel[0]}" "arm64 uses an Image, not a bzImage"
}

test_pine64_keeps_its_own_kernel() {
    composition_load "gentoo-sway-pine64" "arm64"

    assert_equals "Image-pine64" "${comp_kernel[0]}" "pine64 needs its own kernel build"
    assert_equals "sway" "${comp_provider_arg[0]}" "the -pine64 suffix is not part of the flavour"
}

test_combined_image_has_one_slot_per_system() {
    composition_load "containeros-virt" "amd64"

    assert_equals "3" "$(comp_count)" "gentoo, nomadbsd and u-root"
    assert_equals "gentoo-containeros" "${comp_name[0]}"
    assert_equals "nomadbsd" "${comp_name[1]}"
    assert_equals "u-root" "${comp_name[2]}"
}

test_combined_image_numbers_partitions_past_the_esp() {
    composition_load "containeros-virt" "amd64"

    assert_equals "3" "${comp_part[0]}" "the first rootfs lands after the esp"
    assert_equals "4" "${comp_part[1]}" "the second rootfs follows it"
    assert_equals "0" "${comp_part[2]}" "an initramfs-only slot gets no partition"
}

test_combined_image_shares_one_kernel_between_slots() {
    composition_load "containeros-virt" "amd64"

    assert_equals "${comp_kernel[0]}" "${comp_kernel[2]}" \
                  "u-root boots the kernel the gentoo slot installs"
}

test_combined_image_is_large_enough_for_every_slot() {
    composition_load "containeros-virt" "amd64"

    local size
    size="$(composition_disk_size_mib)"

    # 3MiB ahead of the esp, the esp itself, both rootfs slots and a
    # 4MiB tail for the backup GPT
    assert_equals "$((3 + 512 + 10240 + 6144 + 4))" "${size}" \
                  "the disk covers the esp and every sized slot"
}

test_unknown_target_falls_back_to_a_single_rootfs() {
    composition_load "some-unknown-target" "amd64"

    assert_equals "1" "$(comp_count)" "an undescribed target still gets a rootfs"
    assert_equals "3" "${comp_part[0]}"
    assert_equals "none" "${comp_boot_type[0]}" "but no boot entry is invented for it"
}

test_linux_boot_entry_names_its_root_and_kernel() {
    local f
    f="$(mktemp)"

    create_boot_entry "${f}" "gentoo" "linux" "Image-virt-arm64" "" \
                      "PARTUUID=abc" "rw quiet"

    assert_equals "title         gentoo" "$(sed -n 1p "${f}")"
    assert_equals "linux         /Image-virt-arm64" "$(sed -n 2p "${f}")"
    assert_equals "options       root=PARTUUID=abc rw quiet" "$(sed -n 3p "${f}")"

    rm -f "${f}"
}

test_initramfs_boot_entry_has_an_initrd_and_no_root() {
    local f
    f="$(mktemp)"

    create_boot_entry "${f}" "u-root" "linux" "bzImage-virt-amd64" \
                      "initramfs-amd64.cpio" "" "console=tty0"

    assert_equals "initrd        /initramfs-amd64.cpio" "$(sed -n 3p "${f}")"
    assert_equals "options       console=tty0" "$(sed -n 4p "${f}")"
    assert_status_code 1 "grep -q 'root=' ${f}"

    rm -f "${f}"
}

test_efi_boot_entry_chainloads_a_loader() {
    local f
    f="$(mktemp)"

    create_boot_entry "${f}" "nomadbsd" "efi" "EFI/nomadbsd/loader.efi" "" "" ""

    assert_equals "efi           /EFI/nomadbsd/loader.efi" "$(sed -n 2p "${f}")"
    assert_status_code 1 "grep -q 'options' ${f}"

    rm -f "${f}"
}

test_unknown_boot_type_is_rejected() {
    local f
    f="$(mktemp)"

    assert_fails "create_boot_entry ${f} title bogus kernel '' '' ''" \
                 "an unknown boot type is not silently written out"

    rm -f "${f}"
}

test_partitions_are_laid_out_in_slot_order() {
    composition_load "containeros-virt" "amd64"

    parted() { echo "parted $*"; }
    sgdisk() { :; }

    local out
    out="$(create_disk_parts_gpt "/tmp/test.raw")"

    assert_matches "mkpart esp fat32 3MiB 515MiB" "${out}" "the esp follows the reserved area"
    assert_matches "mkpart gentoo-containeros xfs 515MiB 10755MiB" "${out}" \
                   "the first rootfs starts where the esp ends"
    assert_matches "mkpart nomadbsd ufs 10755MiB 16899MiB" "${out}" \
                   "the second rootfs starts where the first ends"

    unset -f parted sgdisk
}

test_gpt_type_codes_match_the_filesystems() {
    assert_equals "A503" "$(gpt_type_code ufs)" "freebsd's loader finds its root by type"
    assert_equals "8300" "$(gpt_type_code xfs)"
    assert_equals "0700" "$(gpt_type_code vfat)"
}

test_ufs_partition_is_found_in_a_gpt_image() {
    sfdisk() {
        printf 'img1 : start=  2048, size= 532480, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, uuid=A\n'
        printf 'img2 : start=534528, size=9203712, type=516E7CB6-6ECF-11D6-8FF8-00022D09712B, uuid=B\n'
    }

    assert_equals "534528 9203712" "$(image_partition_range img ufs)"
    assert_equals "2048 532480" "$(image_partition_range img esp)"

    unset -f sfdisk
}

test_ufs_partition_is_found_in_an_mbr_image() {
    sfdisk() {
        printf 'img1 : start=  2048, size= 102400, type=ef\n'
        printf 'img2 : start=104448, size=9203712, type=a5\n'
    }

    assert_equals "104448 9203712" "$(image_partition_range img ufs)"
    assert_equals "2048 102400" "$(image_partition_range img esp)"

    unset -f sfdisk
}

test_missing_ufs_partition_is_reported_rather_than_guessed() {
    sfdisk() {
        printf 'img1 : start=2048, size=100, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4\n'
    }

    assert_fails "image_partition_range img ufs" \
                 "an image without a UFS partition is not silently accepted"

    unset -f sfdisk
}

test_nomadbsd_maps_only_the_arches_upstream_builds() {
    assert_equals "amd64" "$(nomadbsd_arch amd64)"
    assert_equals "amd64" "$(nomadbsd_arch x86_64)"
    assert_equals "i386" "$(nomadbsd_arch i386)"
    assert_equals "mac" "$(nomadbsd_arch mac)"
    assert_equals "" "$(nomadbsd_arch arm64)" "upstream publishes no arm64 image"
    assert_equals "" "$(nomadbsd_arch riscv64)"
}

test_nomadbsd_image_name_follows_the_arch() {
    assert_equals "nomadbsd-${nomadbsd_version}.amd64.ufs.img" \
                  "$(nomadbsd_image_file amd64)"
    assert_equals "nomadbsd-${nomadbsd_version}.i386.ufs.img" \
                  "$(nomadbsd_image_file i386)"
}

test_nomadbsd_image_path_prefers_an_explicit_image() {
    assert_equals "/tmp/built.img" \
                  "$(NOMADBSD_IMAGE=/tmp/built.img nomadbsd_image_path /dl amd64)" \
                  "NOMADBSD_IMAGE overrides the fetched name"
    assert_equals "/dl/nomadbsd-${nomadbsd_version}.amd64.ufs.img" \
                  "$(NOMADBSD_IMAGE='' nomadbsd_image_path /dl amd64)"
}

test_nomadbsd_arch_gate_passes_arches_upstream_builds() {
    assert "NOMADBSD_IMAGE='' nomadbsd_require_arch amd64 ctx"
    assert "NOMADBSD_IMAGE='' nomadbsd_require_arch i386 ctx"
}

test_nomadbsd_arch_gate_refuses_arm64() {
    assert_fails "NOMADBSD_IMAGE='' nomadbsd_require_arch arm64 ctx" \
                 "there is no arm64 NomadBSD image to compose"
    assert_fails "NOMADBSD_IMAGE='' nomadbsd_fetch /tmp arm64" \
                 "and fetching one is refused before any download"
}

test_nomadbsd_arch_gate_yields_to_an_explicit_image() {
    assert "NOMADBSD_IMAGE=/tmp/mine.img nomadbsd_require_arch arm64 ctx" \
           "a supplied image is the caller's business"
}

test_nomadbsd_can_not_be_built_for_arm64() {
    # Stub the host check, so this exercises the architecture check
    # rather than passing because the test host is not FreeBSD
    sys_os() { echo "freebsd"; }

    assert_fails "nomadbsd_build arm64" \
                 "upstream's build system takes amd64, i386 or mac"

    unset -f sys_os
}

test_nomadbsd_build_needs_a_freebsd_host() {
    sys_os() { echo "fedora"; }

    assert_fails "nomadbsd_build amd64" \
                 "NomadBSD's build system only runs on FreeBSD"

    unset -f sys_os
}

test_checksum_verify_reads_the_bsd_format() {
    local f
    f="$(mktemp)"
    printf 'hello\n' > "${f}"

    local c
    c="$(mktemp)"
    printf 'SHA256 (%s) = 5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03\n' \
           "$(basename "${f}")" > "${c}"

    assert "checksum_verify ${c} ${f} sha256" "the BSDs publish 'SHA256 (file) = hash'"

    rm -f "${f}" "${c}"
}

test_checksum_verify_reads_the_coreutils_format() {
    local f
    f="$(mktemp)"
    printf 'hello\n' > "${f}"

    local c
    c="$(mktemp)"
    printf '5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03  %s\n' \
           "$(basename "${f}")" > "${c}"

    assert "checksum_verify ${c} ${f} sha256"

    rm -f "${f}" "${c}"
}

test_checksum_verify_rejects_a_mismatch() {
    local f
    f="$(mktemp)"
    printf 'hello\n' > "${f}"

    local c
    c="$(mktemp)"
    printf 'SHA256 (x) = %064d\n' 0 > "${c}"

    assert_fails "checksum_verify ${c} ${f} sha256"

    rm -f "${f}" "${c}"
}

test_a_shared_kernel_is_copied_to_the_esp_once() {
    local d
    d="$(mktemp -d)"
    mkdir -p "${d}/esp" "${d}/src"
    echo kernel > "${d}/src/bzImage-virt-amd64-latest"
    echo loader > "${d}/src/nomadbsd-loader.efi"
    echo initrd > "${d}/src/initramfs-amd64.cpio"

    composition_load "containeros-virt" "amd64"

    local i
    for i in "${!comp_name[@]}"; do
        esp_install_file "${d}/src" "${comp_kernel_src[$i]}" \
                         "${d}/esp" "${comp_kernel[$i]}"
        esp_install_file "${d}/src" "${comp_initrd_src[$i]}" \
                         "${d}/esp" "${comp_initrd[$i]}"
    done

    assert_equals "3" "$(find "${d}/esp" -type f | wc -l | tr -d ' ')" \
                  "one kernel, one initramfs and one EFI loader"
    assert "test -f ${d}/esp/bzImage-virt-amd64"
    assert "test -f ${d}/esp/initramfs-amd64.cpio"
    assert "test -f ${d}/esp/EFI/nomadbsd/loader.efi"

    rm -rf "${d}"
}

test_combined_image_is_refused_where_its_bsd_slot_has_no_image() {
    assert_fails "NOMADBSD_IMAGE='' composition_load containeros-virt arm64" \
                 "the whole target is limited by its NomadBSD slot"
}

test_combined_image_composes_where_every_slot_exists() {
    NOMADBSD_IMAGE='' composition_load "containeros-virt" "amd64"

    assert_equals "3" "$(comp_count)" "all three slots on amd64"
    assert_equals "bzImage-virt-amd64" "${comp_kernel[0]}" "with the amd64 kernel"
    assert_equals "initramfs-amd64.cpio" "${comp_initrd[2]}" "and the amd64 initramfs"
    assert_equals "amd64" "${comp_provider_arg[1]}" "the BSD slot is told the arch"
}

test_u_root_slot_fetches_its_own_initramfs() {
    composition_load "containeros-virt" "amd64"

    assert_equals "u-root" "${comp_provider[2]}" "the slot has a provider that fetches"
    assert_equals "amd64" "${comp_provider_arg[2]}" "which is told the arch to fetch for"
    assert_equals "initramfs-amd64.cpio" "${comp_initrd_src[2]}" \
                  "the initramfs is fetched into the download path"
    assert_equals "none" "${comp_fs[2]}" "and it still needs no partition"
}

# Build a disk image carrying a BSD disklabel in a slice, the layout
# FreeBSD-derived images such as NomadBSD's actually use
make_labelled_image() {
    local img
    img="${1}"
    local slice_start
    slice_start="${2}"
    shift 2

    dd if=/dev/zero of="${img}" bs=1024 count=64 2>/dev/null

    local label
    label=$(( (slice_start + 1) * 512 ))

    # 0x82564557, little endian
    printf '\x57\x45\x56\x82' | \
        dd of="${img}" bs=1 seek="${label}" conv=notrunc 2>/dev/null

    # d_npartitions at +138
    printf '\x08\x00' | \
        dd of="${img}" bs=1 seek="$((label + 138))" conv=notrunc 2>/dev/null

    # Each remaining argument is one "size_le4:offset_le4:fstype" entry
    local i
    i=0
    local spec
    for spec in "$@"; do
        local entry
        entry=$((label + 148 + i * 16))

        printf "$(echo "${spec}" | cut -d: -f1)" | \
            dd of="${img}" bs=1 seek="${entry}" conv=notrunc 2>/dev/null
        printf "$(echo "${spec}" | cut -d: -f2)" | \
            dd of="${img}" bs=1 seek="$((entry + 4))" conv=notrunc 2>/dev/null
        printf "$(echo "${spec}" | cut -d: -f3)" | \
            dd of="${img}" bs=1 seek="$((entry + 12))" conv=notrunc 2>/dev/null

        i=$((i + 1))
    done
}

test_read_uint_le_reads_widths() {
    local img
    img="$(mktemp)"
    printf '\x57\x45\x56\x82' > "${img}"

    assert_equals "2186691927" "$(read_uint_le "${img}" 0 4)" "the disklabel magic"
    assert_equals "17751" "$(read_uint_le "${img}" 0 2)" "its low half"

    rm -f "${img}"
}

test_disklabel_ufs_partition_is_found_inside_a_slice() {
    local img
    img="$(mktemp)"

    # partition a: size 8280064 sectors, offset 2048, fstype 7 (UFS)
    make_labelled_image "${img}" 64 '\x00\x58\x7e\x00:\x00\x08\x00\x00:\x07\x00\x00\x00'

    # The offset is slice relative, so the result is 64 + 2048
    assert_equals "2112 8280064" "$(bsd_label_ufs_range "${img}" 64)" \
                  "the UFS partition sits inside the slice, not at its start"

    rm -f "${img}"
}

test_disklabel_skips_non_ufs_partitions() {
    local img
    img="$(mktemp)"

    # entry 0 is swap (fstype 1), entry 1 is the UFS partition
    make_labelled_image "${img}" 64 \
        '\x00\x08\x00\x00:\x00\x08\x00\x00:\x01\x00\x00\x00' \
        '\x00\x58\x7e\x00:\x00\x10\x00\x00:\x07\x00\x00\x00'

    assert_equals "4160 8280064" "$(bsd_label_ufs_range "${img}" 64)" \
                  "a swap partition ahead of the filesystem is skipped"

    rm -f "${img}"
}

test_a_slice_without_a_disklabel_is_reported_as_such() {
    local img
    img="$(mktemp)"
    dd if=/dev/zero of="${img}" bs=1024 count=64 2>/dev/null

    assert_fails "bsd_label_ufs_range ${img} 64" \
                 "no magic means no label to descend into"

    rm -f "${img}"
}

test_ufs_range_descends_into_a_disklabel() {
    local img
    img="$(mktemp)"
    make_labelled_image "${img}" 64 '\x00\x58\x7e\x00:\x00\x08\x00\x00:\x07\x00\x00\x00'

    # A FreeBSD MBR slice, as sfdisk reports one
    sfdisk() { printf 'img1 : start=  64, size= 8282112, type=a5\n'; }

    assert_equals "2112 8280064" "$(image_ufs_range "${img}")" \
                  "the nested filesystem wins over the slice it sits in"

    unset -f sfdisk
    rm -f "${img}"
}

test_ufs_range_falls_back_to_a_bare_slice() {
    local img
    img="$(mktemp)"
    dd if=/dev/zero of="${img}" bs=1024 count=64 2>/dev/null

    # A GPT freebsd-ufs partition holds a filesystem directly
    sfdisk() {
        printf 'img1 : start=2048, size=9203712, type=516E7CB6-6ECF-11D6-8FF8-00022D09712B\n'
    }

    assert_equals "2048 9203712" "$(image_ufs_range "${img}")" \
                  "a partition holding a filesystem directly is used as is"

    unset -f sfdisk
    rm -f "${img}"
}

test_fs_check_uses_the_generic_fsck_helper() {
    fs_check_cmd vfat /dev/loop0p2
    assert_equals "fsck.vfat -n /dev/loop0p2" "${fs_check_argv[*]}" \
                  "a filesystem with a working fsck helper needs no special case"

    fs_check_cmd f2fs /dev/loop0p9
    assert_equals "fsck.f2fs -n /dev/loop0p9" "${fs_check_argv[*]}" \
                  "including one the script has never heard of"
}

test_fs_check_overrides_helpers_that_do_not_check() {
    # fsck.xfs and fsck.btrfs are no-op stubs, so the generic branch
    # would silently verify nothing
    fs_check_cmd xfs /dev/loop0p3
    assert_equals "xfs_repair -n /dev/loop0p3" "${fs_check_argv[*]}"

    fs_check_cmd btrfs /dev/loop0p3
    assert_equals "btrfs check --readonly /dev/loop0p3" "${fs_check_argv[*]}"
}

test_fs_check_forces_a_check_on_ext() {
    fs_check_cmd ext4 /dev/loop0p3
    assert_equals "e2fsck -f -n /dev/loop0p3" "${fs_check_argv[*]}" \
                  "-f checks a filesystem already marked clean"
}

test_fs_check_knows_the_bsd_name_for_ufs() {
    fs_check_cmd ufs /dev/loop0p4
    assert_equals "fsck_ffs -n /dev/loop0p4" "${fs_check_argv[*]}" \
                  "util-linux ships no fsck.ufs"
}

test_fs_check_reports_an_undetected_filesystem() {
    assert_fails "fs_check_cmd '' /dev/loop0p3" \
                 "an empty type is not turned into an fsck. command"
}

test_fs_check_commands_are_read_only() {
    local fs
    for fs in xfs btrfs ext4 ufs vfat f2fs; do
        fs_check_cmd "${fs}" /dev/loop0p3
        assert_matches "(-n|--readonly)" "${fs_check_argv[*]}" \
                       "the ${fs} check must not modify the filesystem"
    done
}

test_fs_prepare_replays_only_a_dirty_log_filesystem() {
    local replayed
    replayed=""
    replay_log_xfs() { replayed="${1}"; }

    fs_prepare xfs /dev/loop0p3
    assert_equals "/dev/loop0p3" "${replayed}" "xfs_repair refuses a dirty log"

    replayed=""
    fs_prepare vfat /dev/loop0p2
    assert_equals "" "${replayed}" "other filesystems need no log replay"

    unset -f replay_log_xfs
}

test_verify_filesystem_skips_a_checker_that_is_not_installed() {
    findmnt() { return 1; }
    blkid() { echo "zfs_member"; }

    assert "verify_filesystem /dev/null 'test'" \
           "a missing checker is skipped rather than failing the build"

    unset -f findmnt blkid
}

test_edk2_firmware_spec_names_the_per_arch_build() {
    local code vars pad

    read -r code vars pad <<< "$(edk2_firmware_spec amd64)"
    assert_equals "RELEASEX64_OVMF_CODE.fd" "${code}"
    assert_equals "RELEASEX64_OVMF_VARS.fd" "${vars}"
    assert_equals "0" "${pad}" "q35 takes the split OVMF build as built"

    read -r code vars pad <<< "$(edk2_firmware_spec arm64)"
    assert_equals "RELEASEAARCH64_QEMU_EFI.fd" "${code}"
    assert_equals "64" "${pad}" "the arm64 virt machine needs a 64MiB pflash"
}

test_edk2_firmware_spec_refuses_an_unbuilt_arch() {
    assert_fails "edk2_firmware_spec riscv64"
}

test_edk2_pad_grows_firmware_to_the_pflash_size() {
    local f
    f="$(mktemp)"
    dd if=/dev/zero of="${f}" bs=1024 count=64 2>/dev/null

    edk2_pad "${f}" 1
    assert_equals "1048576" "$(wc -c < "${f}" | tr -d ' ')" "padded to 1MiB"

    # Running again must not grow it further
    edk2_pad "${f}" 1
    assert_equals "1048576" "$(wc -c < "${f}" | tr -d ' ')" "padding is idempotent"

    rm -f "${f}"
}

test_edk2_pad_refuses_to_shrink_firmware() {
    local f
    f="$(mktemp)"
    # Larger than the pflash it would be padded to
    dd if=/dev/zero of="${f}" bs=1024 count=2048 2>/dev/null

    assert_fails "edk2_pad ${f} 1" "truncating firmware would corrupt it"

    rm -f "${f}"
}

test_firmware_paths_uses_a_supplied_directory() {
    local d
    d="$(mktemp -d)"
    touch "${d}/RELEASEX64_OVMF_CODE.fd" "${d}/RELEASEX64_OVMF_VARS.fd"

    assert_equals "${d}/RELEASEX64_OVMF_CODE.fd ${d}/RELEASEX64_OVMF_VARS.fd" \
                  "$(EDK2_DIR="${d}" firmware_paths /unused amd64)" \
                  "EDK2_DIR is used instead of fetching"

    rm -rf "${d}"
}

test_firmware_paths_reports_an_incomplete_directory() {
    local d
    d="$(mktemp -d)"
    touch "${d}/RELEASEX64_OVMF_CODE.fd"

    assert_fails "EDK2_DIR=${d} firmware_paths /unused amd64" \
                 "firmware without its variable store is not usable"

    rm -rf "${d}"
}

test_qemu_binary_and_machine_follow_the_arch() {
    assert_equals "qemu-system-x86_64" "$(qemu_bin_for_arch amd64)"
    assert_equals "qemu-system-aarch64" "$(qemu_bin_for_arch arm64)"
    assert_equals "" "$(qemu_bin_for_arch riscv64)"

    assert_equals "q35" "$(qemu_machine_for_arch amd64)"
    assert_matches "virt" "$(qemu_machine_for_arch arm64)"
}

test_qemu_uses_kvm_only_for_a_matching_host() {
    sys_arch() { echo "amd64"; }

    assert_equals "kvm" "$(qemu_accel_for_arch amd64)" "a matching guest can use kvm"
    assert_equals "kvm" "$(qemu_accel_for_arch x86_64)" "however the arch is spelled"
    assert_equals "tcg" "$(qemu_accel_for_arch arm64)" "a foreign guest has to be emulated"

    unset -f sys_arch
}

test_qemu_cpu_matches_the_accelerator() {
    assert_equals "host" "$(qemu_cpu_for_arch arm64 kvm)"
    assert_equals "max" "$(qemu_cpu_for_arch arm64 tcg)"
}

test_boot_test_pattern_follows_the_provider() {
    assert_equals "login:" "$(BOOT_TEST_PATTERN='' boot_test_pattern gentoo)" \
                  "a systemd slot is up once it runs a getty"
    assert_equals "u-root" "$(BOOT_TEST_PATTERN='' boot_test_pattern u-root)"
    assert_equals "FreeBSD" "$(BOOT_TEST_PATTERN='' boot_test_pattern nomadbsd)"
}

test_boot_test_pattern_can_be_overridden() {
    assert_equals "my marker" \
                  "$(BOOT_TEST_PATTERN='my marker' boot_test_pattern gentoo)"
}

test_boot_test_fails_on_output_that_means_a_dead_guest() {
    local p
    p="$(boot_test_fail_pattern)"

    local line
    for line in \
        "Kernel panic - not syncing: VFS: Unable to mount root fs" \
        "BdsDxe: No bootable option or device was found." \
        "mountroot: waiting for device /dev/ufs/rootfs"
    do
        assert "echo '${line}' | grep -qE '${p}'" \
               "should be treated as a failed boot: ${line}"
    done
}

test_boot_test_does_not_fail_a_healthy_boot() {
    local p
    p="$(boot_test_fail_pattern)"

    # systemd reports individual unit failures on boots that go on to
    # reach a login prompt, so these must not abort the test
    local line
    for line in \
        "[FAILED] Failed to start Load Kernel Modules." \
        "systemd[1]: Failed to start chronyd.service." \
        "gentoo login:"
    do
        assert_fails "echo '${line}' | grep -qE '${p}'" \
                     "should not be treated as a failed boot: ${line}"
    done
}

test_boot_test_recognises_a_booted_slot() {
    # The marker each provider's default pattern looks for
    assert "echo 'gentoo login:' | grep -qE \"$(BOOT_TEST_PATTERN='' boot_test_pattern gentoo)\""
    assert "echo 'Welcome to u-root!' | grep -qE \"$(BOOT_TEST_PATTERN='' boot_test_pattern u-root)\""
    assert "echo 'FreeBSD/amd64 (nomad) (ttyu0)' | grep -qE \"$(BOOT_TEST_PATTERN='' boot_test_pattern nomadbsd)\""
}

test_serial_console_follows_the_arch() {
    # qemu's arm64 virt machine has a pl011, not an 8250
    assert_matches "ttyAMA0" "$(linux_cmdline_console arm64)"
    assert_matches "ttyS0" "$(linux_cmdline_console amd64)"

    assert_matches "ttyAMA0" "$(linux_cmdline_default arm64)" \
                  "the default cmdline carries the right console too"
    assert_matches "init=/lib/systemd/systemd" "$(linux_cmdline_default amd64)"
}

test_composition_gives_each_slot_the_right_console() {
    composition_load "gentoo-containeros" "arm64"
    assert_matches "ttyAMA0" "${comp_cmdline[0]}" "an arm64 image logs to ttyAMA0"

    NOMADBSD_IMAGE='' composition_load "containeros-virt" "amd64"
    assert_matches "ttyS0" "${comp_cmdline[0]}" "an amd64 image logs to ttyS0"
    assert_matches "ttyS0" "${comp_cmdline[2]}" "including the initramfs slot"
}
