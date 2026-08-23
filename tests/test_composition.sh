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
    assert_equals "Image-arm64-vm" "${comp_kernel[0]}" "arm64 uses an Image, not a bzImage"
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

    create_boot_entry "${f}" "gentoo" "linux" "Image-arm64-vm" "" \
                      "PARTUUID=abc" "rw quiet"

    assert_equals "title         gentoo" "$(sed -n 1p "${f}")"
    assert_equals "linux         /Image-arm64-vm" "$(sed -n 2p "${f}")"
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

test_nomadbsd_maps_only_the_architectures_upstream_publishes() {
    assert_equals "amd64" "$(nomadbsd_arch amd64)"
    assert_equals "amd64" "$(nomadbsd_arch x86_64)"
    assert_equals "i386" "$(nomadbsd_arch i386)"
    assert_equals "mac" "$(nomadbsd_arch mac)"
    assert_equals "" "$(nomadbsd_arch arm64)" "upstream publishes no arm64 image"
}

test_nomadbsd_refuses_an_architecture_it_can_not_fetch() {
    assert_fails "NOMADBSD_IMAGE='' nomadbsd_fetch /tmp arm64" \
                 "fetching arm64 fails rather than requesting a 404"
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
    mkdir -p "${d}/src/output"
    echo initrd > "${d}/src/output/initramfs-amd64.cpio"

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

test_combined_image_is_arch_parameterized() {
    composition_load "containeros-virt" "arm64"

    assert_equals "3" "$(comp_count)" "the same three slots on arm64"
    assert_equals "Image-arm64-vm" "${comp_kernel[0]}" "with the arm64 kernel"
    assert_equals "initramfs-arm64.cpio" "${comp_initrd[2]}" "and the arm64 initramfs"
    assert_equals "arm64" "${comp_provider_arg[1]}" "the BSD slot is told the arch"
}
