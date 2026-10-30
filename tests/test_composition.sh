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
# shellcheck disable=SC2034,SC2154,SC2329

setup_suite() {
    SCRIPT_UNDER_TEST="$(dirname "${BASH_SOURCE[0]}")/../image-builder"
    LIB="$(mktemp)"

    # Source the function definitions without running main
    sed '/^args=("\$@")$/,$d' "${SCRIPT_UNDER_TEST}" >"${LIB}"

    DEBUG=0
    SEND_NOTIFICATION=0

    # shellcheck disable=SC1090
    source "${LIB}"

    # Set after sourcing: the script sets log_level itself
    log_level=quiet
    # The units and the scripts they run: A cfg-services checkout next to image-builder
    cfg_services="${CFG_SERVICES:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/cfg-services}"
}

teardown_suite() {
    rm -f "${LIB}"
}

test_gentoo_composition_has_one_rootfs_and_refind() {
    composition_load "gentoo-containeros" "arm64"

    assert_equals "2" "$(comp_count)" "the rootfs and rEFInd, no NomadBSD on arm64"
    assert_equals "16384" "$(composition_disk_size_mib)" "disk stays 16GiB"
    assert_equals "3" "${comp_part[0]}" "its rootfs is p3"
    assert_equals "rest" "${comp_size[0]}" "its rootfs fills the disk"
    assert_equals "xfs" "${comp_fs[0]}" "its rootfs is xfs"
    assert_equals "Image-virt-arm64" "${comp_kernel[0]}" "arm64 uses an Image, not a bzImage"
    assert_equals "refind" "${comp_name[1]}"
    assert_equals "0" "${comp_part[1]}" "rEFInd lives on the ESP"
    assert_equals "EFI/refind/refind_aa64.efi" "${comp_kernel[1]}"
}

test_gentoo_image_carries_nomadbsd_on_amd64() {
    composition_load "gentoo-sway" "amd64"

    assert_equals "nomadbsd gentoo-sway gentoo-sway-x230 gentoo-sway-x201 refind" "${comp_name[*]}"
    assert_equals "3 4 0 0 0" "${comp_part[*]}" "the Gentoo rootfs stays last, so it can grow"
    assert_equals "$((16384 + 6144))" "$(composition_disk_size_mib)"
    assert_equals "gentoo-sway" "${comp_default}" "Gentoo stays the default entry"
}

test_exclude_drops_a_slot_and_its_space() {
    EXCLUDE_IMAGES="nomadbsd" composition_load "gentoo-sway" "amd64"

    assert_equals "gentoo-sway gentoo-sway-x230 gentoo-sway-x201 refind" "${comp_name[*]}"
    assert_equals "3" "${comp_part[0]}"
    assert_equals "16384" "$(composition_disk_size_mib)" "NomadBSD's 6GiB go with it"
}

test_exclude_can_leave_nomadbsd_alone() {
    EXCLUDE_IMAGES="gentoo-sway refind" composition_load "gentoo-sway" "amd64"

    assert_equals "nomadbsd" "${comp_name[*]}"
    assert_equals "$((3 + 256 + 6144 + 4))" "$(composition_disk_size_mib)" \
        "without the growing rootfs the disk is sized from its slots"
    assert_equals "" "${comp_default}" "the first remaining slot becomes the default"
}

test_exclude_can_leave_refind_alone() {
    EXCLUDE_IMAGES="gentoo-sway nomadbsd" composition_load "gentoo-sway" "amd64"

    assert_equals "refind" "${comp_name[*]}"
    assert_equals "$((3 + 256 + 4))" "$(composition_disk_size_mib)" "an ESP and nothing else"
}

test_exclude_refuses_a_name_the_image_does_not_have() {
    assert_fails "EXCLUDE_IMAGES=typo composition_load gentoo-sway amd64" \
        "a typo is not silently ignored"
    assert_fails "EXCLUDE_IMAGES=nomadbsd composition_load gentoo-sway-pine64 arm64" \
        "nor a slot this arch never has"
}

test_exclude_refuses_to_leave_nothing() {
    assert_fails "EXCLUDE_IMAGES='gentoo-sway nomadbsd refind' composition_load gentoo-sway amd64"
}

test_refind_follows_the_arch() {
    assert_equals "x64" "$(refind_efiarch amd64)"
    assert_equals "aa64" "$(refind_efiarch arm64)"
    assert_equals "" "$(refind_efiarch riscv64)"

    composition_reset
    composition_add_refind riscv64
    assert_equals "0" "$(comp_count)" "no slot where rEFInd ships no binary"
}

test_refind_fetch_keeps_a_staged_binary() {
    local d
    d="$(mktemp -d)"
    echo efi >"${d}/refind_x64.efi"

    assert "refind_fetch ${d} amd64" "a staged binary needs no download"

    rm -rf "${d}"
}

test_refind_fetch_refuses_a_zip_with_the_wrong_checksum() {
    local d
    d="$(mktemp -d)"
    echo notazip >"${d}/refind-bin-${refind_version}.zip"

    assert_fails "refind_fetch ${d} amd64" "the pinned SHA512 has to match"
    assert "test ! -f ${d}/refind_x64.efi" "and nothing is extracted"

    rm -rf "${d}"
}

test_pine64_keeps_its_own_kernel() {
    composition_load "gentoo-sway-pine64" "arm64"

    assert_equals "Image-pine64" "${comp_kernel[0]}" "pine64 needs its own kernel build"
    assert_equals "sway" "${comp_provider_arg[0]}" "the -pine64 suffix is not part of the flavour"
}

test_combined_image_has_one_slot_per_system() {
    composition_load "containeros-virt" "amd64"

    assert_equals "4" "$(comp_count)" "gentoo, nomadbsd, u-root and rEFInd"
    assert_equals "gentoo-containeros" "${comp_name[0]}"
    assert_equals "nomadbsd" "${comp_name[1]}"
    assert_equals "u-root" "${comp_name[2]}"
    assert_equals "refind" "${comp_name[3]}"
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
    assert_matches "mkpart nomadbsd 10755MiB 16899MiB" "${out}" \
        "the second rootfs starts where the first ends"

    unset -f parted sgdisk
}

test_gpt_type_codes_match_the_filesystems() {
    assert_equals "A503" "$(gpt_type_code ufs)" "freebsd's loader finds its root by type"
    assert_equals "A504" "$(gpt_type_code zfs freebsd)"
    assert_equals "BF01" "$(gpt_type_code zfs gentoo)" \
        "a Linux pool must not look like a FreeBSD root to loader.efi"
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

test_zfs_partition_is_found_in_a_freebsd_vm_image() {
    # Makefile.vm's amd64 layout: gptzfsboot, the ESP, then the pool
    sfdisk() {
        printf 'img1 : start=    40, size=   1024, type=83BD6B9D-7F41-11DC-BE0B-001560B84F0F, uuid=A\n'
        printf 'img2 : start=  1064, size=  66584, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, uuid=B\n'
        printf 'img3 : start= 67648, size=4194304, type=516E7CBA-6ECF-11D6-8FF8-00022D09712B, uuid=C\n'
    }

    assert_equals "67648 4194304" "$(image_partition_range img zfs)"
    assert_equals "1064 66584" "$(image_partition_range img esp)"
    assert_fails "image_partition_range img ufs" "a pool is not mistaken for UFS"

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
    printf 'hello\n' >"${f}"

    local c
    c="$(mktemp)"
    printf 'SHA256 (%s) = 5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03\n' \
        "$(basename "${f}")" >"${c}"

    assert "checksum_verify ${c} ${f} sha256" "the BSDs publish 'SHA256 (file) = hash'"

    rm -f "${f}" "${c}"
}

test_checksum_verify_reads_the_coreutils_format() {
    local f
    f="$(mktemp)"
    printf 'hello\n' >"${f}"

    local c
    c="$(mktemp)"
    printf '5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03  %s\n' \
        "$(basename "${f}")" >"${c}"

    assert "checksum_verify ${c} ${f} sha256"

    rm -f "${f}" "${c}"
}

test_checksum_verify_rejects_a_mismatch() {
    local f
    f="$(mktemp)"
    printf 'hello\n' >"${f}"

    local c
    c="$(mktemp)"
    printf 'SHA256 (x) = %064d\n' 0 >"${c}"

    assert_fails "checksum_verify ${c} ${f} sha256"

    rm -f "${f}" "${c}"
}

test_compare_checksums_matches_the_full_sha384() {
    local f
    f="$(mktemp)"
    printf 'hello\n' >"${f}"

    local c
    c="$(mktemp)"
    printf '1d0f284efe3edea4b9ca3bd514fa134b17eae361ccc7a1eefeff801b9bd6604e01f21f6bf249ef030599f0c218f2ba8c  %s\n' \
        "other-name" >"${c}"

    assert_equals "0" "$(compare_checksums "${c}" "${f}")" \
        "releases name the file without -latest, so only the hash counts"

    rm -f "${f}" "${c}"
}

test_compare_checksums_rejects_a_difference_after_64_digits() {
    local f
    f="$(mktemp)"
    printf 'hello\n' >"${f}"

    local c
    c="$(mktemp)"
    printf '1d0f284efe3edea4b9ca3bd514fa134b17eae361ccc7a1eefeff801b9bd6604e%032d  %s\n' \
        0 "$(basename "${f}")" >"${c}"

    assert_equals "1" "$(compare_checksums "${c}" "${f}")" \
        "a sha384 has 96 hex digits and all of them have to match"

    rm -f "${f}" "${c}"
}

test_compare_checksums_rejects_a_missing_checksum_file() {
    local f
    f="$(mktemp)"
    printf 'hello\n' >"${f}"

    assert_equals "1" "$(compare_checksums "${f}.sha384" "${f}" 2>/dev/null)"

    rm -f "${f}"
}

make_test_repo() {
    git init -q -b main "${1}"
    printf 'main\n' >"${1}/branch"
    git -C "${1}" add branch
    git -C "${1}" -c user.name=t -c user.email=t@t commit -q -m main
    git -C "${1}" checkout -q -b other
    printf 'other\n' >"${1}/branch"
    git -C "${1}" -c user.name=t -c user.email=t@t commit -q -am other
    git -C "${1}" checkout -q main
}

test_git_fresh_clone_replaces_a_leftover_clone() {
    local d
    d="$(mktemp -d)"
    make_test_repo "${d}/src"

    mkdir -p "${d}/work/gentoo-config"
    touch "${d}/work/gentoo-config/stale"

    (cd "${d}/work" && git_fresh_clone gentoo-config "file://${d}/src") >/dev/null 2>&1
    assert_equals 0 "$?" "a clone left by an earlier run should not stop the next one"
    assert_equals "main" "$(cat "${d}/work/gentoo-config/branch")"
    assert_fails "test -e ${d}/work/gentoo-config/stale" \
        "the leftover clone should be replaced, not reused"

    rm -rf "${d}"
}

test_git_fresh_clone_passes_clone_options() {
    local d
    d="$(mktemp -d)"
    make_test_repo "${d}/src"

    (cd "${d}" && git_fresh_clone out/repo -b other "file://${d}/src") >/dev/null 2>&1
    assert_equals 0 "$?"
    assert_equals "other" "$(cat "${d}/out/repo/branch")"

    rm -rf "${d}"
}

test_every_clone_goes_through_git_fresh_clone() {
    assert_equals "1" "$(awk '/git clone/ { n++ } END { print n + 0 }' "${SCRIPT_UNDER_TEST}")" \
        "a bare git clone fails when an earlier run left its folder behind"
}

test_a_shared_kernel_is_copied_to_the_esp_once() {
    local d
    d="$(mktemp -d)"
    mkdir -p "${d}/esp" "${d}/src"
    echo kernel >"${d}/src/bzImage-virt-amd64-latest"
    echo loader >"${d}/src/nomadbsd-loader.efi"
    echo initrd >"${d}/src/initramfs-amd64.cpio"
    echo refind >"${d}/src/refind_x64.efi"

    composition_load "containeros-virt" "amd64"

    local i
    for i in "${!comp_name[@]}"; do
        esp_install_file "${d}/src" "${comp_kernel_src[$i]}" \
            "${d}/esp" "${comp_kernel[$i]}"
        esp_install_file "${d}/src" "${comp_initrd_src[$i]}" \
            "${d}/esp" "${comp_initrd[$i]}"
    done

    assert_equals "4" "$(find "${d}/esp" -type f | wc -l | tr -d ' ')" \
        "one kernel, one initramfs and two EFI loaders"
    assert "test -f ${d}/esp/bzImage-virt-amd64"
    assert "test -f ${d}/esp/initramfs-amd64.cpio"
    assert "test -f ${d}/esp/EFI/nomadbsd/loader.efi"
    assert "test -f ${d}/esp/EFI/refind/refind_x64.efi"

    rm -rf "${d}"
}

test_combined_image_is_refused_where_its_bsd_slot_has_no_image() {
    assert_fails "NOMADBSD_IMAGE='' composition_load containeros-virt arm64" \
        "the whole target is limited by its NomadBSD slot"
}

test_combined_image_composes_where_every_slot_exists() {
    NOMADBSD_IMAGE='' composition_load "containeros-virt" "amd64"

    assert_equals "4" "$(comp_count)" "all four slots on amd64"
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
    label=$(((slice_start + 1) * 512))

    # 0x82564557, little endian
    printf '\x57\x45\x56\x82' |
        dd of="${img}" bs=1 seek="${label}" conv=notrunc 2>/dev/null

    # d_npartitions at +138
    printf '\x08\x00' |
        dd of="${img}" bs=1 seek="$((label + 138))" conv=notrunc 2>/dev/null

    # Each remaining argument is one "size_le4:offset_le4:fstype" entry
    local i
    i=0
    local spec
    for spec in "$@"; do
        local entry
        entry=$((label + 148 + i * 16))

        printf '%b' "$(echo "${spec}" | cut -d: -f1)" |
            dd of="${img}" bs=1 seek="${entry}" conv=notrunc 2>/dev/null
        printf '%b' "$(echo "${spec}" | cut -d: -f2)" |
            dd of="${img}" bs=1 seek="$((entry + 4))" conv=notrunc 2>/dev/null
        printf '%b' "$(echo "${spec}" | cut -d: -f3)" |
            dd of="${img}" bs=1 seek="$((entry + 12))" conv=notrunc 2>/dev/null

        i=$((i + 1))
    done
}

test_read_uint_le_reads_widths() {
    local img
    img="$(mktemp)"
    printf '\x57\x45\x56\x82' >"${img}"

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
    blkid() { echo "nofs"; }

    assert "verify_filesystem /dev/null 'test'" \
        "a missing checker is skipped rather than failing the build"

    unset -f findmnt blkid
}

test_edk2_firmware_spec_names_the_per_arch_build() {
    local code vars pad

    read -r code vars pad <<<"$(edk2_firmware_spec amd64)"
    assert_equals "RELEASEX64_OVMF_CODE.fd" "${code}"
    assert_equals "RELEASEX64_OVMF_VARS.fd" "${vars}"
    assert_equals "0" "${pad}" "q35 takes the split OVMF build as built"

    read -r code vars pad <<<"$(edk2_firmware_spec arm64)"
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
    assert_equals "1048576" "$(wc -c <"${f}" | tr -d ' ')" "padded to 1MiB"

    # Running again must not grow it further
    edk2_pad "${f}" 1
    assert_equals "1048576" "$(wc -c <"${f}" | tr -d ' ')" "padding is idempotent"

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
    assert_matches "highmem-ecam=off" "$(qemu_machine_for_arch arm64)" \
        "9qemu only finds PCI config space at the low ECAM window"
}

test_arm64_qemu_devices_are_modern_virtio() {
    assert_matches "disable-legacy=on" "$(qemu_disk_args arm64 /x.raw)" \
        "9qemu's virtio drivers only bind non-transitional devices"
    assert_equals "virtio-net-pci-non-transitional" "$(qemu_nic_model_for_arch arm64)"
    assert_equals "-drive format=raw,file=/x.raw" "$(qemu_disk_args amd64 /x.raw | tr '\n' ' ' | sed 's/ $//')"
    assert_equals "virtio-net-pci" "$(qemu_nic_model_for_arch amd64)"
}

test_qemu_uses_kvm_only_for_a_matching_host() {
    sys_arch() { echo "amd64"; }

    local native
    native="tcg"
    if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
        native="kvm"
    fi

    assert_equals "${native}" "$(qemu_accel_for_arch amd64)" "a matching guest uses kvm where it is usable"
    assert_equals "${native}" "$(qemu_accel_for_arch x86_64)" "however the arch is spelled"
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
    assert_equals "rEFInd - Main Menu" "$(BOOT_TEST_PATTERN='' boot_test_pattern refind)"
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
        "mountroot: waiting for device /dev/ufs/rootfs"; do
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
        "gentoo login:"; do
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

test_board_pins_the_architecture_it_can_run() {
    # armhf here is ARMv6: a pi zero or pi1
    assert_equals "armhf" "$(board_arch rpi0)"
    assert_equals "armhf" "$(board_arch rpi0w)"
    assert_equals "armhf" "$(board_arch rpi1)"
    assert_equals "armv7" "$(board_arch rpi2)"
    assert_equals "arm64" "$(board_arch rpi3)"
    assert_equals "arm64" "$(board_arch rpi4)"
    assert_equals "arm64" "$(board_arch pine64)"
    assert_equals "amd64" "$(board_arch x230)"
    assert_equals "" "$(board_arch not-a-board)"
}

test_pi_zero_2_is_arm64_despite_the_name() {
    assert_equals "arm64" "$(board_arch rpi02w)" \
        "the zero 2 W is a cortex-a53, unlike the original zero"
}

test_boot_method_follows_the_board() {
    assert_equals "rpi-firmware" "$(board_boot_method rpi0)"
    assert_equals "rpi-firmware" "$(board_boot_method rpi4)"
    assert_equals "uefi" "$(board_boot_method pine64)"
    assert_equals "uefi" "$(board_boot_method x230)"
}

test_target_names_are_split_into_flavour_and_board() {
    assert_equals "rpi0" "$(target_board alpine-containeros-rpi0)"
    assert_equals "containeros" "$(target_flavour_of alpine-containeros-rpi0 alpine-)"

    assert_equals "rpi2" "$(target_board alpine-sway-rpi2)"
    assert_equals "sway" "$(target_flavour_of alpine-sway-rpi2 alpine-)"

    assert_equals "pine64" "$(target_board gentoo-sway-pine64)"
    assert_equals "sway" "$(target_flavour_of gentoo-sway-pine64 gentoo-)"
}

test_a_target_without_a_board_keeps_its_whole_flavour() {
    assert_equals "" "$(target_board alpine-containeros)"
    assert_equals "containeros" "$(target_flavour_of alpine-containeros alpine-)"

    # 'virt' is part of the flavour, not a board
    assert_equals "" "$(target_board gentoo-sway-virt)"
    assert_equals "sway-virt" "$(target_flavour_of gentoo-sway-virt gentoo-)"
    assert_equals "" "$(target_board containeros-virt)"
}

test_alpine_architecture_names_are_translated() {
    assert_equals "aarch64" "$(alpine_arch_for arm64)"
    assert_equals "armv7" "$(alpine_arch_for armv7)"
    assert_equals "armhf" "$(alpine_arch_for armhf)"
    assert_equals "" "$(alpine_arch_for amd64)" "the Alpine images are arm boards only"
}

test_container_platform_covers_32_bit_arm() {
    assert_equals "linux/arm/v7" "$(container_platform armv7)"
    assert_equals "linux/arm/v6" "$(container_platform armhf)"
    assert_equals "linux/arm64" "$(container_platform arm64)"
    assert_equals "" "$(container_platform riscv64)"
}

test_no_kernel_is_published_for_32_bit_arm() {
    assert_equals "" "$(kernel_file_for_arch armhf)" \
        "those boards take their kernel from their Alpine image"
    assert_equals "" "$(kernel_file_for_arch armv7)"
    assert_equals "Image-virt-arm64" "$(kernel_file_for_arch arm64)"
}

test_a_pi_is_refused_an_esp_and_systemd_boot_layout() {
    assert_fails "require_uefi_board gentoo-containeros-rpi0" \
        "a pi cannot boot an ESP, so building one would be a dead image"
    assert_fails "require_uefi_board gentoo-containeros-rpi4" \
        "not even the 64 bit pis, without third party UEFI firmware"
}

test_uefi_boards_and_boardless_targets_are_allowed() {
    assert "require_uefi_board gentoo-sway-pine64" "u-boot chainloads systemd-boot"
    assert "require_uefi_board gentoo-containeros" "no board named, nothing to check"
    assert "require_uefi_board containeros-virt"
}

test_freebsd_is_left_out_unless_included() {
    composition_load "gentoo-sway-pine64" "arm64"

    assert_status_code 1 "composition_has freebsd" "optional, so not composed by default"
}

test_freebsd_is_the_only_bsd_on_arm64() {
    INCLUDE_IMAGES="freebsd" composition_load "gentoo-sway-pine64" "arm64"

    assert_equals "freebsd gentoo-sway refind" "${comp_name[*]}"
    assert_equals "3 4 0" "${comp_part[*]}" "ahead of the Gentoo rootfs, which stays last"
    assert_equals "zfs" "${comp_fs[0]}"
    assert_equals "efi" "${comp_boot_type[0]}"
    assert_equals "EFI/freebsd/loader.efi" "${comp_kernel[0]}"
    assert_equals "$((16384 + freebsd_slot_size))" "$(composition_disk_size_mib)"
    assert_equals "rootdev=zfs:zroot/ROOT/default:" "${comp_cmdline[0]}" \
        "a ZFS root is named by its dataset, which needs no disk index"
    assert_equals "gentoo-sway" "${comp_default}" "Gentoo stays the default entry"
}

test_freebsd_sits_next_to_nomadbsd_on_amd64() {
    INCLUDE_IMAGES="freebsd" composition_load "gentoo-sway" "amd64"

    assert_equals "nomadbsd freebsd gentoo-sway gentoo-sway-x230 gentoo-sway-x201 refind" "${comp_name[*]}"
    assert_equals "3 4 5 0 0 0" "${comp_part[*]}"
    assert_equals "$((16384 + 6144 + freebsd_slot_size))" "$(composition_disk_size_mib)"
    assert_equals "" "${comp_cmdline[0]}" "NomadBSD comes first, the loader's walk finds it"
    assert_equals "rootdev=zfs:zroot/ROOT/default:" "${comp_cmdline[1]}" \
        "pinned, or its loader would boot NomadBSD's root first"
}

test_freebsd_stays_pinned_once_nomadbsd_is_excluded() {
    INCLUDE_IMAGES="freebsd" EXCLUDE_IMAGES="nomadbsd" composition_load "gentoo-sway" "amd64"

    assert_equals "freebsd gentoo-sway gentoo-sway-x230 gentoo-sway-x201 refind" "${comp_name[*]}"
    assert_equals "3" "${comp_part[0]}"
    assert_equals "rootdev=zfs:zroot/ROOT/default:" "${comp_cmdline[0]}"
}

test_a_second_ufs_root_is_pinned_by_partition() {
    composition_reset
    composition_add "nomadbsd" "nomadbsd" "amd64" "ufs" "6144" "" "" "" "" "" "efi"
    composition_add "freebsd" "freebsd" "amd64" "ufs" "2048" "" "" "" "" "" "efi"
    comp_part=(3 4)

    composition_pin_bsd_rootdev

    assert_equals "" "${comp_cmdline[0]}" "the first UFS root keeps the loader's walk"
    assert_equals "rootdev=disk0p4:" "${comp_cmdline[1]}"
}

test_freebsd_rootdev_reaches_the_boot_entry() {
    local f
    f="$(mktemp)"

    create_boot_entry "${f}" "freebsd" "efi" "EFI/freebsd/loader.efi" "" "" "rootdev=zfs:zroot/ROOT/default:"

    assert_equals "efi           /EFI/freebsd/loader.efi" "$(sed -n 2p "${f}")"
    assert_equals "options       rootdev=zfs:zroot/ROOT/default:" "$(sed -n 3p "${f}")" \
        "systemd-boot passes options as the loader's load options"

    rm -f "${f}"
}

test_include_refuses_a_slot_the_target_does_not_offer() {
    assert_fails "INCLUDE_IMAGES=typo composition_load gentoo-sway amd64" \
        "a typo is not silently ignored"
    assert_fails "INCLUDE_IMAGES=freebsd composition_load nomadbsd amd64" \
        "nor a target that never composes the slot"
}

test_freebsd_arch_gate_refuses_arches_freebsd_build_does_not_build() {
    assert_fails "INCLUDE_IMAGES=freebsd composition_load gentoo-sway armv7"
    assert "FREEBSD_IMAGE=/some/image freebsd_require_arch armv7 test" \
        "an explicit image is the caller's business"
}

test_freebsd_image_name_follows_the_arch_and_filesystem() {
    assert_equals "freebsd-${freebsd_image_version}-arm64-zfs.img" \
        "$(freebsd_image_file aarch64)"
    assert_equals "freebsd-${freebsd_image_version}-amd64-ufs.img" \
        "$(freebsd_rootfs_fs=ufs freebsd_image_file x86_64)"
}

test_freebsd_image_path_prefers_an_explicit_image() {
    assert_equals "/tmp/x.img" "$(FREEBSD_IMAGE=/tmp/x.img freebsd_image_path /dl arm64)"
    assert_equals "/dl/$(freebsd_image_file arm64)" "$(freebsd_image_path /dl arm64)"
}

test_plan9_partition_is_typed_and_left_unhinted() {
    assert_equals "3900" "$(gpt_type_code plan9)"
    assert_equals "" "$(parted_fs_hint plan9)" "parted knows no Plan 9 filesystem"
}

test_plan9_partition_is_found_in_an_mbr_image() {
    sfdisk() {
        printf 'img1 : start=    63, size=7720897, type=39, bootable\n'
    }

    assert_equals "63 7720897" "$(image_partition_range img plan9)"
    assert_fails "image_partition_range img esp" "an MBR Plan 9 disk has no ESP"

    unset -f sfdisk
}

test_plan9_partition_is_found_in_a_gpt_image() {
    sfdisk() {
        printf 'img1 : start=  2048, size= 532480, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, uuid=A\n'
        printf 'img2 : start=534528, size=8388608, type=C91818F9-8025-47AF-89D2-F030D7000C2C, uuid=B\n'
    }

    assert_equals "534528 8388608" "$(image_partition_range img plan9)"

    unset -f sfdisk
}

test_9front_is_left_out_unless_included() {
    composition_load "gentoo-sway" "amd64"

    assert_status_code 1 "composition_has 9front" "optional, so not composed by default"
}

test_9front_sits_ahead_of_the_gentoo_rootfs() {
    INCLUDE_IMAGES="9front" composition_load "gentoo-sway" "amd64"

    assert_equals "nomadbsd 9front gentoo-sway gentoo-sway-x230 gentoo-sway-x201 refind" "${comp_name[*]}"
    assert_equals "3 4 5 0 0 0" "${comp_part[*]}"
    assert_equals "plan9" "${comp_fs[1]}"
    assert_equals "efi" "${comp_boot_type[1]}"
    assert_equals "EFI/9front/bootx64.efi" "${comp_kernel[1]}"
    assert_equals "" "${comp_cmdline[1]}" "its root is named in plan9.ini, not the load options"
    assert_equals "$((16384 + 6144 + ninefront_slot_size))" "$(composition_disk_size_mib)"
    assert_equals "gentoo-sway" "${comp_default}"
}

test_9front_composes_next_to_freebsd() {
    INCLUDE_IMAGES="freebsd 9front" composition_load "gentoo-sway" "amd64"

    assert_equals "nomadbsd freebsd 9front gentoo-sway gentoo-sway-x230 gentoo-sway-x201 refind" "${comp_name[*]}"
    assert_equals "rootdev=zfs:zroot/ROOT/default:" "${comp_cmdline[1]}"
}

test_gentoo_sway_boots_every_amd64_kernel_from_one_root() {
    composition_load "gentoo-sway" "amd64"

    assert_equals "nomadbsd gentoo-sway gentoo-sway-x230 gentoo-sway-x201 refind" "${comp_name[*]}"
    assert_equals "gentoo-kernel gentoo-kernel" "${comp_provider[2]} ${comp_provider[3]}"
    assert_equals "gentoo-sway gentoo-sway" "${comp_provider_arg[2]} ${comp_provider_arg[3]}" \
        "the hardware kernels boot the Gentoo slot's root"
    assert_equals "bzImage-x230-latest bzImage-x230" "${comp_kernel_src[2]} ${comp_kernel[2]}"
    assert_equals "bzImage-x201-latest bzImage-x201" "${comp_kernel_src[3]} ${comp_kernel[3]}"
    assert_equals "bzImage-virt-amd64" "${comp_kernel[1]}" "the Gentoo slot keeps the virt kernel"
    assert_equals "0 0" "${comp_part[2]} ${comp_part[3]}" "kernel entries get no partition"
    assert_equals "1" "${comp_default_saved}"
    assert_matches "init=/lib/systemd/systemd" "${comp_cmdline[2]}"
}

test_gentoo_sway_boots_every_arm64_kernel_from_one_root() {
    composition_load "gentoo-sway" "arm64"

    assert_equals "gentoo-sway gentoo-sway-pine64 gentoo-sway-rockpro64 refind" "${comp_name[*]}"
    assert_equals "Image-pine64 dtb-pine64" "${comp_kernel[1]} ${comp_dtb[1]}"
    assert_equals "Image-rockpro64 dtb-rockpro64" "${comp_kernel[2]} ${comp_dtb[2]}"
    assert_matches "console=ttyS0,115200n8" "${comp_cmdline[1]}" "pine64's UART"
    assert_matches "console=ttyS2,115200n8" "${comp_cmdline[2]}" "rockpro64's UART"
    assert_matches "console=ttyAMA0,115200n8" "${comp_cmdline[0]}" "qemu virt's UART"
}

test_other_gentoo_sway_targets_keep_a_single_kernel() {
    local t
    for t in "gentoo-sway-virt amd64" "gentoo-sway-pine64 arm64"; do
        # shellcheck disable=SC2086 # target and arch, word split on purpose
        composition_load ${t}
        assert_equals "" "$(printf '%s\n' "${comp_provider[@]}" | grep -x gentoo-kernel)" "${t}"
        assert_equals "" "${comp_default_saved}" "${t}"
    done
}

test_excluding_the_gentoo_slot_drops_its_kernels() {
    EXCLUDE_IMAGES="gentoo-sway" composition_load "gentoo-sway" "amd64"

    assert_equals "nomadbsd refind" "${comp_name[*]}" \
        "a kernel entry without its root would not boot"
}

test_kernel_entries_are_fetched_with_their_device_trees() {
    local log
    log="$(mktemp)"
    # The dtb is fetched in a subshell, so record to a file
    download_miss() { basename "${2}" >>"${log}"; }
    gentoo_fetch_stage3() { :; }
    gentoo_fetch_stage4() { :; }
    refind_fetch() { :; }

    composition_load "gentoo-sway" "arm64"
    composition_fetch /tmp arm64 >/dev/null 2>&1

    local fetched
    fetched="$(tr '\n' ' ' <"${log}")"
    assert_matches "Image-pine64-latest dtb-pine64-latest" "${fetched}"
    assert_matches "Image-rockpro64-latest dtb-rockpro64-latest" "${fetched}"

    unset -f download_miss gentoo_fetch_stage3 gentoo_fetch_stage4 refind_fetch
    rm -f "${log}"
}

test_kernel_entries_boot_the_gentoo_partition_and_the_last_entry_picked() {
    local d
    d="$(mktemp -d)"
    reexec_privileged() { :; }
    esp_mount() { :; }
    unmount_recursive() { :; }
    part_dev() { echo "/dev/test-p${1}"; }
    blkid() { echo "PU-${*: -1}"; }

    composition_load "gentoo-sway" "amd64"
    install_boot_entries /dev/test-p2 "${d}" >/dev/null

    local e="${d}/loader/entries"
    assert_matches "root=PARTUUID=PU-/dev/test-p4 " "$(cat "${e}/gentoo-sway-x230.conf")" \
        "x230 boots the Gentoo slot, p4 after nomadbsd's p3"
    assert_matches "linux         /bzImage-x230" "$(cat "${e}/gentoo-sway-x230.conf")"
    assert_matches "root=PARTUUID=PU-/dev/test-p4 " "$(cat "${e}/gentoo-sway.conf")"
    assert_matches "default @saved" "$(cat "${d}/loader/loader.conf")"
    assert_matches "sort-key      a" "$(cat "${e}/gentoo-sway.conf")" \
        "with nothing saved yet, @saved boots the entry sorting first"
    assert_matches "sort-key      b-02" "$(cat "${e}/gentoo-sway-x230.conf")"

    unset -f reexec_privileged esp_mount unmount_recursive part_dev blkid
    rm -rf "${d}"
}

test_single_kernel_targets_keep_a_fixed_default() {
    local d
    d="$(mktemp -d)"
    reexec_privileged() { :; }
    esp_mount() { :; }
    unmount_recursive() { :; }
    part_dev() { echo "/dev/test-p${1}"; }
    blkid() { echo "PU-${*: -1}"; }

    composition_load "gentoo-sway-virt" "amd64"
    install_boot_entries /dev/test-p2 "${d}" >/dev/null

    assert_matches "default gentoo-sway-virt.conf" "$(cat "${d}/loader/loader.conf")"
    assert_fails "grep -q sort-key ${d}/loader/entries/gentoo-sway-virt.conf"

    unset -f reexec_privileged esp_mount unmount_recursive part_dev blkid
    rm -rf "${d}"
}

test_boot_test_keeps_the_images_loader_conf_intact() {
    local d
    d="$(mktemp -d)"
    mkdir -p "${d}/loader/entries"
    printf 'default @saved\ntimeout 5\n' >"${d}/loader/loader.conf"
    touch "${d}/loader/entries/gentoo-sway.conf"

    loop_mount() { echo "Loop mounting ${1}"; }
    loop_unmount() { echo "loop_unmount"; }
    esp() { echo "/dev/test-p2"; }
    esp_mount() { echo "TARGET SOURCE FSTYPE OPTIONS"; }
    unmount_recursive() { echo "unmount_recursive: unmounting ${1}"; }

    local previous
    previous="$(boot_test_select_entry /tmp/test.raw "${d}" gentoo-sway 2>/dev/null)"

    assert_equals "$(printf 'default @saved\ntimeout 5')" "${previous}" \
        "only the image's loader.conf is put back, not the mount helpers' output"
    assert_matches "default gentoo-sway.conf" "$(cat "${d}/loader/loader.conf")"

    unset -f loop_mount loop_unmount esp esp_mount unmount_recursive
    rm -rf "${d}"
}

test_boot_test_skips_hardware_kernels_unless_named() {
    composition_load "gentoo-sway" "amd64"

    assert_equals "" "$(boot_test_skip_reason 1 "")" "the Gentoo slot boots under qemu"
    assert_matches "hardware kernel" "$(boot_test_skip_reason 2 "")"
    assert_equals "" "$(boot_test_skip_reason 2 "gentoo-sway-x230")" \
        "a hardware kernel asked for by name is booted"
    assert_equals "login:" "$(BOOT_TEST_PATTERN='' boot_test_pattern gentoo-kernel)"
}

test_portage_snapshot_comes_from_the_stage4() {
    local d
    d="$(mktemp -d)"
    mkdir -p "${d}/etc/gentoo-build"

    assert_equals "" "$(GENTOO_PORTAGE_SNAPSHOT='' gentoo_portage_snapshot "${d}")" \
        "an older stage4 without a record syncs the latest tree"

    printf '20261019\n' >"${d}/etc/gentoo-build/portage-snapshot"
    assert_equals "20261019" "$(GENTOO_PORTAGE_SNAPSHOT='' gentoo_portage_snapshot "${d}")" \
        "the tree the binpkgs were built against keeps them matching"
    assert_equals "20261001" "$(GENTOO_PORTAGE_SNAPSHOT=20261001 gentoo_portage_snapshot "${d}")" \
        "GENTOO_PORTAGE_SNAPSHOT overrides the stage4's record"

    assert_fails "GENTOO_PORTAGE_SNAPSHOT=latest gentoo_portage_snapshot ${d} 2>/dev/null" \
        "only a YYYYMMDD date reaches emerge-webrsync --revert"

    rm -rf "${d}"
}

test_overlays_come_from_the_stage4() {
    local d
    d="$(mktemp -d)"
    mkdir -p "${d}/etc/gentoo-build"

    assert_equals "" "$(GENTOO_OVERLAYS='' gentoo_stage4_overlays "${d}")"

    printf 'https://github.com/bbusse/bbusse-overlay\n' >"${d}/etc/gentoo-build/overlays"
    assert_equals "https://github.com/bbusse/bbusse-overlay" \
        "$(GENTOO_OVERLAYS='' gentoo_stage4_overlays "${d}")" \
        "binpkgs built from an overlay ebuild need that overlay"

    printf 'https://a.example/x  https://b.example/y\n\n' >"${d}/etc/gentoo-build/overlays"
    assert_equals "https://a.example/x https://b.example/y" \
        "$(GENTOO_OVERLAYS='' gentoo_stage4_overlays "${d}")"

    assert_equals "https://c.example/z" \
        "$(GENTOO_OVERLAYS=https://c.example/z gentoo_stage4_overlays "${d}")" \
        "GENTOO_OVERLAYS overrides the stage4's record"

    rm -rf "${d}"
}

test_9front_partition_gets_no_fs_hint() {
    INCLUDE_IMAGES="9front" EXCLUDE_IMAGES="nomadbsd" composition_load "gentoo-sway" "amd64"
    parted() { echo "parted $*"; }
    sgdisk() { :; }

    local out
    out="$(create_disk_parts_gpt "/tmp/test.raw")"

    assert_matches "mkpart 9front 259MiB $((259 + ninefront_slot_size))MiB" "${out}"

    unset -f parted sgdisk
}

test_filesystem_probes_the_partition_without_udev() {
    loop_mount() { echo "Loop mounting ${1}"; }
    loop_unmount() { echo "unmount_recursive: unmounting /mnt/disk-image"; }
    loop_device() { echo "/dev/loop3"; }
    lsblk() { :; }
    blkid() {
        if [ "-p -o value -s TYPE /dev/loop3p5" = "$*" ]; then
            echo "xfs"
        fi
    }

    assert_equals "xfs" "$(filesystem /tmp/test.raw 5 2>/dev/null)" \
        "lsblk's fstype comes from udev, which a container may not have"
    assert_matches "Loop mounting /tmp/test.raw" "$(filesystem /tmp/test.raw 5 2>&1 >/dev/null)" \
        "loop_mount's messages go to stderr, not into the filesystem type"

    unset -f loop_mount loop_unmount loop_device lsblk blkid
}

test_9p_automount_is_installed_and_enabled_inside_the_image() {
    local d
    d="$(mktemp -d)"
    mkdir -p "${d}/usr/local/sbin" "${d}/etc/systemd/system"

    virtio_9p_automount "${d}"

    local script unit link
    script="${d}/usr/local/sbin/9p-automount"
    unit="${d}/etc/systemd/system/9p-automount.service"
    link="${d}/etc/systemd/system/multi-user.target.wants/9p-automount.service"

    assert "test -x ${script}"
    assert "sh -n ${script}" "the script should parse"
    assert_matches "/sys/bus/virtio/devices/\*/mount_tag" "$(cat "${script}")"
    assert_matches "mount -t 9p -o trans=virtio" "$(cat "${script}")"

    assert_matches "ExecStart=/usr/local/sbin/9p-automount" "$(cat "${unit}")"
    assert_matches "Type=oneshot" "$(cat "${unit}")"
    assert_matches "WantedBy=multi-user.target" "$(cat "${unit}")"

    assert "test -L ${link}"
    assert_equals "../9p-automount.service" "$(readlink "${link}")" \
        "a link to the build-time mount path dangles once the image boots"
    assert "test -f ${link}" "the enable link should resolve to the unit inside the image"

    rm -rf "${d}"
}

test_no_symlink_in_the_image_points_at_the_build_mount_path() {
    local d
    d="$(mktemp -d)"
    mkdir -p "${d}/etc/systemd/system/getty.target.wants" "${d}/etc/systemd/user" \
        "${d}/etc/systemd/network" "${d}/usr/local/sbin" "${d}/usr/local/bin" \
        "${d}/usr/lib/systemd/system" "${d}/usr/bin" "${d}/usr/share/zoneinfo/UTC" \
        "${d}/home/u"
    touch "${d}/usr/lib/systemd/system/bluetooth.service"
    touch "${d}/usr/lib/systemd/system/systemd-networkd-wait-online.service"
    touch "${d}/usr/bin/bt-agent"
    chmod 755 "${d}/usr/bin/bt-agent"

    chroot() { :; }
    sudo() { :; }
    systemctl() { :; }
    download() { :; }
    download_miss() { :; }
    curl() { :; }
    git() { :; }
    podman() { :; }

    local c
    for c in "enable_bluetooth_sink ${d}" \
        "write_swapfile_unit ${d}" \
        "provision_systemd_firstboot ${d} u" \
        "write_provision_fetch ${d} u" \
        "write_booted_service ${d} host" \
        "write_net_config ${d} arm64 iproute2-static eth0 10.0.0.2/24" \
        "write_net_config ${d} arm64 systemd-networkd-dhcp" \
        "add_dhcp_client ${d} arm64" \
        "service_enable ${d} sshd multi-user" \
        "virtio_9p_automount ${d}"; do
        (${c}) >/dev/null 2>&1 || true
    done

    unset -f chroot sudo systemctl download download_miss curl git podman

    local s="${d}/etc/systemd/system"
    local l
    for l in bluetooth.target.wants/bt-agent.service \
        bluetooth.target.wants/set-bt-discoverable.service \
        swap.target.wants/swapfile.swap \
        sysinit.target.wants/firstboot-provision@u.service \
        multi-user.target.wants/fetch-provision@u.service \
        getty.target.wants/booted.service \
        getty.target.wants/net-config.service \
        getty.target.wants/net-interface.path \
        multi-user.target.wants/net-dhcp.service \
        network-online.target.wants/systemd-networkd-wait-online.service \
        multi-user.target.wants/sshd.service \
        multi-user.target.wants/9p-automount.service; do
        assert "test -L ${s}/${l}" "$(printf '%s should have been enabled' "${l}")"
    done

    local bad
    bad="$(find "${d}" -type l | while read -r l; do
        case "$(readlink "${l}")" in
        "${d}"*) printf '%s -> %s\n' "${l#"${d}"}" "$(readlink "${l}")" ;;
        esac
    done)"

    assert_equals "" "${bad}" \
        "a link to the build-time mount path dangles once the image boots"

    local misnamed
    misnamed="$(find "${d}" -type l -path '*.wants/*' | while read -r l; do
        local name unit
        name="$(basename "${l}")"
        unit="$(basename "$(readlink "${l}")")"
        case "${name}" in
        *@?*.*) name="${name%%@*}@.${name##*.}" ;;
        esac
        if [ "${name}" != "${unit}" ]; then
            printf '%s -> %s\n' "${l#"${d}"}" "$(readlink "${l}")"
        fi
    done)"

    assert_equals "" "${misnamed}" \
        "systemd enables the unit a .wants link is named after, not the one it points to"

    rm -rf "${d}"
}

test_nothing_reads_device_metadata_from_udev() {
    local hits
    hits="$(grep -n -E '\$\( *lsblk|`lsblk|lsblk[^|]*\|[^|]|/dev/disk/by-|/run/udev|udevadm +info|ID_FS_|findfs ' \
        "${SCRIPT_UNDER_TEST}" | grep -v -E '^[0-9]+: *#')"

    assert_equals "" "${hits}" \
        "read filesystem types and ids with blkid, containers and early boot have no udev database"
}

test_filesystem_fails_when_the_partition_has_none() {
    loop_mount() { :; }
    loop_unmount() { :; }
    loop_device() { echo "/dev/loop3"; }
    blkid() { return 2; }

    assert_fails "filesystem /tmp/test.raw 5 2>/dev/null"

    unset -f loop_mount loop_unmount loop_device blkid
}

test_esp_is_named_efiboot0_for_a_freebsd_slot() {
    INCLUDE_IMAGES="freebsd 9front" composition_load "gentoo-sway-virt" "arm64"
    parted() { echo "parted $*"; }
    sgdisk() { :; }

    local out
    out="$(create_disk_parts_gpt "/tmp/test.raw")"

    assert_matches "mkpart efiboot0 fat32 3MiB" "${out}" \
        "FreeBSD's fstab mounts /boot/efi from /dev/gpt/efiboot0"

    unset -f parted sgdisk
}

test_esp_keeps_its_name_without_a_freebsd_slot() {
    INCLUDE_IMAGES="9front" composition_load "gentoo-sway-virt" "arm64"
    parted() { echo "parted $*"; }
    sgdisk() { :; }

    local out
    out="$(create_disk_parts_gpt "/tmp/test.raw")"

    assert_matches "mkpart esp fat32 3MiB" "${out}"

    unset -f parted sgdisk
}

test_9front_is_refused_on_boards() {
    assert_fails "INCLUDE_IMAGES=9front composition_load gentoo-sway-pine64 arm64" \
        "9qemu only boots qemu's virt machine"
}

test_9front_is_refused_off_amd64_and_arm64() {
    assert_fails "ninefront_require_arch armv7 test"
    assert "ninefront_require_arch x86_64 test" "however the arch is spelled"
    assert "ninefront_require_arch aarch64 test" "however the arch is spelled"
}

test_9front_arm64_slot_starts_bootaa64() {
    INCLUDE_IMAGES="9front" composition_load "gentoo-sway" "arm64"

    local i
    for i in "${!comp_name[@]}"; do
        [ "9front" = "${comp_name[$i]}" ] && break
    done
    assert_equals "9front" "${comp_name[$i]}"
    assert_equals "EFI/9front/bootaa64.efi" "${comp_kernel[$i]}"
}

test_9front_arm64_plan9_ini_boots_9qemu_from_virtio() {
    local f
    f="$(mktemp)"

    ninefront_write_plan9_ini "${f}" "arm64"

    assert_equals "bootfile=/EFI/9front/9qemu" "$(grep '^bootfile=' "${f}")"
    assert_equals "nobootprompt=local!/dev/sdF0/fs -A" "$(grep '^nobootprompt=' "${f}")" \
        "qemu's virt machine attaches the disk through virtio"

    rm -f "${f}"
}

test_9front_root_disk_can_be_overridden() {
    assert_equals "sdN0" "$(ninefront_root_disk=sdN0 ninefront_root_disk_name arm64)"
}

test_9front_plan9_ini_boots_its_slot_without_prompting() {
    local f
    f="$(mktemp)"

    ninefront_write_plan9_ini "${f}" "amd64"

    assert_equals "bootfile=/EFI/9front/9pc64" "$(grep '^bootfile=' "${f}")" \
        "the loader reads the kernel from the ESP it was started from"
    assert_equals "nobootprompt=local!/dev/sdE0/fs -A" "$(grep '^nobootprompt=' "${f}")" \
        "gefs is attached with the flags 9front's installer gives it"
    assert_equals "user=glenda" "$(grep '^user=' "${f}")"
    assert_equals "console=0" "$(grep '^console=' "${f}")"

    rm -f "${f}"
}

test_9front_boot_test_waits_for_a_shell() {
    assert_equals "init: starting /bin/rc" "$(BOOT_TEST_PATTERN='' boot_test_pattern 9front)" \
        "headless 9qemu never starts rio, so there is no term% on arm64"
}

test_9front_image_is_named_after_the_release() {
    assert_equals "/dl/9front-${ninefront_version}-amd64.img" "$(ninefront_image_path /dl x86_64)" \
        "named the way 9front-build publishes it"
    assert_equals "/dl/9front-${ninefront_version}-arm64.img" "$(ninefront_image_path /dl aarch64)"
}

test_9front_release_file_follows_release_yml_naming() {
    assert_equals "9front-${ninefront_version}-arm64-latest" "$(ninefront_release_file arm64)"
    assert_equals "9front-${ninefront_version}-amd64-latest" "$(ninefront_release_file amd64)" \
        "release.yml publishes each file as <file>-latest, as it does the kernels"
}

test_9front_image_path_prefers_an_explicit_image() {
    assert_equals "/tmp/x.img" "$(NINEFRONT_IMAGE=/tmp/x.img ninefront_image_path /dl)"
}

test_9front_target_is_a_single_slot() {
    composition_load "9front" "amd64"

    assert_equals "9front" "${comp_name[*]}"
    assert_equals "3" "${comp_part[0]}"
    assert_equals "64" "${comp_esp_size}"
    assert_equals "$((3 + 64 + 4 + ninefront_slot_size))" "$(composition_disk_size_mib)"
}

test_9front_target_builds_for_arm64() {
    composition_load "9front" "arm64"

    assert_equals "EFI/9front/bootaa64.efi" "${comp_kernel[0]}"
    assert_fails "composition_load 9front armv7"
}

test_plan9_slot_skips_the_filesystem_check() {
    composition_load "9front" "amd64"

    local checked
    checked="$(
        bsd_install_fs() { :; }
        verify_filesystem() { echo "${1}"; }
        install_rootfs_slots /mnt /dl
    )"

    assert_equals "" "${checked}" "blkid mistakes the 9fat at the partition's start for the whole partition"
}

test_freebsd_release_file_follows_release_yml_naming() {
    assert_equals "freebsd-${freebsd_image_version}-arm64-zfs-latest" "$(freebsd_release_file aarch64)"
    assert_equals "freebsd-${freebsd_image_version}-amd64-ufs-latest" \
        "$(freebsd_rootfs_fs=ufs freebsd_release_file x86_64)"
    assert_equals "freebsd-${freebsd_image_version}-amd64-latest" "$(freebsd_legacy_release_file x86_64)"
}

test_release_image_fetch_keeps_an_up_to_date_image() {
    local d
    d="$(mktemp -d)"
    touch -t 202601010000 "${d}/x-latest"
    touch -t 202601020000 "${d}/x.img"
    touch "${d}/loader.efi"

    local out
    out="$(
        download_miss() { :; }
        xz() { echo "decompressed"; }
        release_image_fetch "X" "${d}" "https://example.invalid" "x-latest" "${d}/x.img" "${d}/loader.efi"
        echo "rc=$?"
    )"

    assert_equals "rc=0" "${out}" "nothing to decompress when the image is newer than the download"
    assert "test -f ${d}/loader.efi" "the staged loader still matches the image"

    rm -rf "${d}"
}

test_release_image_fetch_refreshes_a_new_image() {
    local d
    d="$(mktemp -d)"
    touch -t 202601010000 "${d}/x.img"
    touch -t 202601020000 "${d}/x-latest"
    touch "${d}/loader.efi"

    (
        download_miss() { :; }
        xz() { echo "new image"; }
        cp() { cat "${2}" >"${3}"; }
        release_image_fetch "X" "${d}" "https://example.invalid" "x-latest" "${d}/x.img" "${d}/loader.efi"
    )

    assert_equals "new image" "$(cat "${d}/x.img")"
    assert_fails "test -f ${d}/loader.efi" "a loader staged from the old image is dropped"
    assert_fails "test -f ${d}/x.img.part"

    rm -rf "${d}"
}

test_release_image_fetch_reports_a_missing_release() {
    assert_fails "( download_miss() { return 1; }; release_image_fetch X /tmp https://example.invalid x-latest /tmp/x.img )"
}

test_u_boot_image_prefers_an_explicit_image() {
    assert_equals "/tmp/u.bin" "$(UBOOT_IMAGE=/tmp/u.bin u_boot_image pine64)"
}

test_u_boot_image_takes_the_first_packaged_one() {
    local d
    d="$(mktemp -d)"
    touch "${d}/b.bin" "${d}/c.bin"

    assert_equals "${d}/b.bin" "$(
        u_boot_candidates() { printf "%s\n" "${d}/a.bin" "${d}/b.bin" "${d}/c.bin"; }
        UBOOT_IMAGE='' u_boot_image pine64
    )"

    rm -rf "${d}"
}

test_u_boot_image_fails_without_a_packaged_one() {
    assert_fails "( u_boot_candidates() { echo /nonexistent/u.bin; }; UBOOT_IMAGE='' u_boot_image pine64 )" \
        "a missing U-Boot is reported rather than written as nothing"
    assert_equals "" "$(u_boot_candidates rockpro64)" "only pine64 is written with U-Boot so far"
}

test_install_u_boot_refuses_a_missing_image() {
    assert_fails "( dd() { echo called; }; install_bootloader_u_boot /nonexistent/u.bin /dev/null )"
}

test_install_u_boot_writes_at_8k_and_syncs() {
    local u
    u="$(mktemp)"

    local args
    args="$(
        dd() { echo "$*"; }
        install_bootloader_u_boot "${u}" /dev/sdX
    )"

    assert_matches "of=/dev/sdX" "${args}"
    assert_matches "bs=1024 seek=8" "${args}" "the Allwinner boot ROM reads the SPL from 8 KiB"
    assert_matches "conv=notrunc,fsync" "${args}"
    assert_fails "( dd() { return 1; }; install_bootloader_u_boot ${u} /dev/sdX )" \
        "a failed write is reported"

    rm -f "${u}"
}

test_mpv_outputs_44k_by_default() {
    local d
    d="$(mktemp -d)"

    write_mpv_config "${d}"

    assert_equals "audio-samplerate=44100" \
        "$(awk '/^\[/ { exit } /^audio-samplerate=/' "${d}/etc/mpv/mpv.conf")" \
        "AirPlay sinks run at 44.1 kHz, resampling for them in PipeWire's RT thread starves the decoder"

    rm -rf "${d}"
}

fake_rootfs_with() {
    local d
    d="$(mktemp -d)"
    local b
    for b in "$@"; do
        mkdir -p "${d}/usr/bin"
        touch "${d}/usr/bin/${b}"
        chmod +x "${d}/usr/bin/${b}"
    done
    echo "${d}"
}

test_board_tv_runs_mpv_on_drm_on_tty1() {
    local d
    d="$(fake_rootfs_with mpv)"

    enable_mpv_tv "${d}" moonshine pine64

    assert "test -L ${d}/etc/systemd/system/role-tv.target.wants/tv-tty1@moonshine.service"
    assert_fails "test -e ${d}/etc/systemd/system/graphical.target.wants/tv-tty1@moonshine.service" \
        "TV is opt-in through role tv"
    assert "grep -qx 'WantedBy=multi-user.target' ${d}/etc/systemd/system/role-tv.target"
    assert_fails "test -e ${d}/etc/systemd/system/multi-user.target.wants/role-tv.target" \
        "provisioning enables the role, the image does not"
    local unit
    unit="$(cat "${d}/etc/systemd/system/tv-tty1@.service")"
    assert_matches "TTYPath=/dev/tty1" "${unit}"
    assert_matches "StandardInput=tty" "${unit}" "mpv releases the display on a VT switch through its tty"
    assert_matches "ExecStart=/usr/local/bin/mpv-tv-vt" "${unit}"
    assert_matches "profile=vt" "$(cat "${d}/usr/local/bin/mpv-tv-vt")" \
        "the VI plane shows the NV12 frames, the GPU only draws the OSD"
    assert_matches "drm-mode=1920x1080@50" "$(cat "${d}/usr/local/bin/mpv-tv-vt")" \
        "the European channels are 50 fps, a 60 Hz mode judders"
    assert_fails "test -e ${d}/etc/systemd/user/mpv-tv.service" "no second mpv inside sway"

    rm -rf "${d}"
}

test_virt_tv_stays_in_sway() {
    local d
    d="$(fake_rootfs_with mpv)"

    enable_mpv_tv "${d}" moonshine ""

    assert "test -L ${d}/etc/systemd/user/sway-session.target.wants/mpv-tv.service"
    assert "test -f ${d}/etc/systemd/system/role-tv.target"
    assert "grep -qx 'ConditionPathExists=/etc/systemd/system/multi-user.target.wants/role-tv.target' ${d}/etc/systemd/user/mpv-tv.service" \
        "a user unit cannot hang off a system target, it checks the role is enabled"
    assert_fails "test -e ${d}/etc/systemd/system/tv-tty1@.service"

    rm -rf "${d}"
}

test_board_sway_starts_on_tty2_on_demand() {
    local d
    d="$(fake_rootfs_with sway)"

    enable_sway_session "${d}" moonshine rockpro64

    local unit
    unit="$(cat "${d}/etc/systemd/system/autovt@tty2.service")"
    assert_fails "grep -q '^User=' ${d}/etc/systemd/system/autovt@tty2.service" \
        "the user lives in a drop-in that provisioning can rewrite"
    assert_equals "$(printf '[Service]\nUser=moonshine\nEnvironmentFile=-/home/moonshine/.config/environment.d/50-provision.conf')" \
        "$(cat "${d}/etc/systemd/system/autovt@tty2.service.d/user.conf")"
    assert_matches "TTYPath=/dev/tty2" "${unit}"
    assert_matches "ExecStart=/usr/bin/sway" "${unit}"
    assert_fails "test -e ${d}/etc/systemd/system/graphical.target.wants/sway-tty1@moonshine.service" \
        "tty1 belongs to the TV, logind starts sway when tty2 is switched to"
    assert "test -L ${d}/etc/systemd/system/default.target"

    rm -rf "${d}"
}

test_virt_sway_keeps_tty1() {
    local d
    d="$(fake_rootfs_with sway)"
    mkdir -p "${d}/etc/systemd/system"

    enable_sway_session "${d}" moonshine ""

    assert "test -L ${d}/etc/systemd/system/graphical.target.wants/sway-tty1@moonshine.service"
    assert_fails "test -e ${d}/etc/systemd/system/autovt@tty2.service"

    rm -rf "${d}"
}

set_default_boot_fixture() {
    local d
    d="${1}"
    mkdir -p "${d}/loader/entries"
    printf 'default @saved\ntimeout 5\nconsole-mode keep\neditor no\n' >"${d}/loader/loader.conf"
    printf 'title gentoo-sway\nsort-key a\n' >"${d}/loader/entries/gentoo-sway.conf"
    printf 'title gentoo-sway-pine64\nsort-key b-01\n' >"${d}/loader/entries/gentoo-sway-pine64.conf"
    printf 'title refind\nsort-key b-03\n' >"${d}/loader/entries/refind.conf"
    printf 'title gentoo-sway-rockpro64\nsort-key b-02\n' >"${d}/loader/entries/gentoo-sway-rockpro64.conf"
}

test_boot_entries_are_listed_in_menu_order() {
    local d
    d="$(mktemp -d)"
    set_default_boot_fixture "${d}"
    printf 'title zz\n' >"${d}/loader/entries/aa-unsorted.conf"

    assert_equals "gentoo-sway gentoo-sway-pine64 gentoo-sway-rockpro64 refind aa-unsorted" \
        "$(boot_entries "${d}" | tr '\n' ' ' | sed 's/ $//')" \
        "sort-key order, entries without one last"

    rm -rf "${d}"
}

test_set_default_boot_picks_an_entry_by_number_or_name() {
    local d
    d="$(mktemp -d)"
    set_default_boot_fixture "${d}"
    local disk
    disk="$(mktemp)"

    MNT="${d}"
    mktemp() { if [ "-d" = "${1}" ]; then echo "${MNT}"; else command mktemp "$@"; fi; }
    rmdir() { :; }
    disk_esp_attach() { echo "attached ${1}" >>"${MNT}/calls"; }
    disk_esp_detach() { echo "detached ${1}" >>"${MNT}/calls"; }

    local out
    out="$(echo 3 | set_default_boot "${disk}" 2>/dev/null)"
    assert_equals 0 "$?"
    assert_matches " 1\) gentoo-sway"$'\n' "${out}"
    assert_matches " 5\) the one last booted \(@saved\)  \(default\)" "${out}" \
        "the current default is marked"
    assert_equals "$(printf 'default gentoo-sway-rockpro64.conf\ntimeout 5\nconsole-mode keep\neditor no')" \
        "$(cat "${d}/loader/loader.conf")" "only the default line changes"

    set_default_boot "${disk}" refind >/dev/null 2>&1
    assert_equals "refind.conf" "$(loader_default "${d}")"

    set_default_boot "${disk}" 5 >/dev/null 2>&1
    assert_equals "@saved" "$(loader_default "${d}")" "the number after the entries is @saved"

    echo "" | set_default_boot "${disk}" >/dev/null 2>&1
    assert_equals "@saved" "$(loader_default "${d}")" "Enter keeps the default"

    set_default_boot "${disk}" 6 >/dev/null 2>&1
    assert_equals 1 "$?" "a number past the list is refused"
    set_default_boot "${disk}" nomadbsd >/dev/null 2>&1
    assert_equals 1 "$?" "a name not on the ESP is refused"
    assert_equals "@saved" "$(loader_default "${d}")"

    assert_equals 6 "$(grep -c '^detached' "${d}/calls")" "the ESP is detached after every run"

    unset -f mktemp rmdir disk_esp_attach disk_esp_detach
    rm -rf "${d}" "${disk}"
}

test_set_default_boot_needs_an_existing_disk() {
    set_default_boot "" >/dev/null 2>&1
    assert_equals 1 "$?"
    set_default_boot /nonexistent/disk.raw >/dev/null 2>&1
    assert_equals 1 "$?"
}

test_set_default_boot_attaches_images_with_hdiutil_on_macos() {
    local calls
    calls="$(mktemp)"
    CALLS="${calls}"

    sys_os() { echo macos; }
    hdiutil() {
        echo "hdiutil $*" >>"${CALLS}"
        if [ "attach" = "${1}" ]; then
            printf '/dev/disk9          \tGUID_partition_scheme\n/dev/disk9s1        \tEFI\n'
        fi
    }
    diskutil() { echo "diskutil $*" >>"${CALLS}"; }

    local attached
    attached="$(disk_esp_attach /tmp/test.raw /tmp/mnt)"
    disk_esp_detach /tmp/mnt "${attached}"

    assert_equals "$(printf '%s\n' \
        "hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount /tmp/test.raw" \
        "diskutil mount -mountPoint /tmp/mnt /dev/disk9s2" \
        "diskutil unmount /tmp/mnt" \
        "hdiutil detach /dev/disk9")" "$(cat "${calls}")"

    unset -f sys_os hdiutil diskutil
    rm -f "${calls}"
}

test_set_default_boot_leaves_a_macos_device_attached() {
    local calls
    calls="$(mktemp)"
    CALLS="${calls}"

    sys_os() { echo macos; }
    hdiutil() { echo "hdiutil $*" >>"${CALLS}"; }
    diskutil() { echo "diskutil $*" >>"${CALLS}"; }

    local attached
    attached="$(disk_esp_attach /dev/disk4 /tmp/mnt)"
    disk_esp_detach /tmp/mnt "${attached}"

    assert_equals "" "${attached}"
    assert_fails "grep -q hdiutil ${calls}" "a card is mounted, never attached or ejected"

    unset -f sys_os hdiutil diskutil
    rm -f "${calls}"
}

test_set_default_boot_loop_mounts_on_linux() {
    local calls
    calls="$(mktemp)"
    CALLS="${calls}"

    sys_os() { echo fedora; }
    loop_mount() {
        echo "loop_mount ${1}" >>"${CALLS}"
        echo "Loop mounting ${1}"
    }
    esp() { echo "/dev/loop0p2"; }
    esp_mount() { echo "esp_mount ${1} ${2}" >>"${CALLS}"; }
    unmount_recursive() { echo "unmount_recursive ${1}" >>"${CALLS}"; }
    loop_unmount() { echo "loop_unmount" >>"${CALLS}"; }

    local attached
    attached="$(disk_esp_attach /tmp/test.raw /tmp/mnt 2>/dev/null)"
    disk_esp_detach /tmp/mnt "${attached}"

    assert_equals "" "${attached}" "the mount helpers' output stays out of the result"
    assert_equals "$(printf '%s\n' \
        "loop_mount /tmp/test.raw" \
        "esp_mount /dev/loop0p2 /tmp/mnt" \
        "unmount_recursive /tmp/mnt" \
        "loop_unmount")" "$(cat "${calls}")"

    unset -f sys_os loop_mount esp esp_mount unmount_recursive loop_unmount
    rm -f "${calls}"
}

test_provision_pins_are_normalised_and_validated() {
    local a
    a="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
    local b
    b="BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="

    assert_equals "" "$(provision_pins "")"
    assert_equals "sha256//${a}" "$(provision_pins "${a}")" "a bare hash gets the sha256// prefix"
    assert_equals "sha256//${a};sha256//${b}" "$(provision_pins " sha256//${a} ; ${b};")"

    provision_pins "sha256//tooshort=" >/dev/null 2>&1
    assert_equals 1 "$?"
    provision_pins "sha1//${a}" >/dev/null 2>&1
    assert_equals 1 "$?" "only sha256 pins"
}

provision_test_keypair() {
    local dir
    dir="${1}"
    local name
    name="${2}"

    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
        -keyout "${dir}/${name}.key" -out "${dir}/${name}.pem" \
        -subj "/CN=${name}" -days 1 >/dev/null 2>&1
}

test_provision_certs_put_certs_key_and_pin_on_the_esp() {
    local d
    d="$(mktemp -d)"
    local f
    f="$(mktemp -d)"
    local disk
    disk="$(mktemp)"
    provision_test_keypair "${f}" ca
    provision_test_keypair "${f}" testdev

    MNT="${d}"
    mktemp() { if [ "-d" = "${1}" ]; then echo "${MNT}"; else command mktemp "$@"; fi; }
    rmdir() { :; }
    disk_esp_attach() { echo "attached ${1}" >>"${MNT}/calls"; }
    disk_esp_detach() { echo "detached ${1}" >>"${MNT}/calls"; }

    provision_pinned_pubkey=""
    provision_certs "${disk}" "${f}/testdev.pem" "${f}/testdev.key" "${f}/ca.pem" >/dev/null 2>&1
    assert_equals 0 "$?"
    assert "cmp -s ${f}/ca.pem ${d}/provision/ca.pem"
    assert "cmp -s ${f}/testdev.pem ${d}/provision/client.pem"
    assert "cmp -s ${f}/testdev.key ${d}/provision/client.key"
    assert_fails "test -e ${d}/provision/pinnedpubkey" "no pin without PROVISION_PINNED_PUBKEY"

    provision_pinned_pubkey="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
    provision_certs "${disk}" "" "" "" >/dev/null 2>&1
    assert_equals 0 "$?" "a pin alone is enough"
    assert_equals "sha256//AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" \
        "$(cat "${d}/provision/pinnedpubkey")"

    assert_equals 2 "$(grep -c '^detached' "${d}/calls")" "the ESP is detached after every run"

    provision_pinned_pubkey=""
    unset -f mktemp rmdir disk_esp_attach disk_esp_detach
    rm -rf "${d}" "${f}" "${disk}"
}

test_provision_add_trust_takes_the_device_certs_from_cfg_provision() {
    local d
    d="$(mktemp -d)"
    local c
    c="$(mktemp -d)"
    local disk
    disk="$(mktemp)"
    mkdir -p "${c}/certs/testdev"
    provision_test_keypair "${c}/certs/testdev" testdev
    provision_test_keypair "${c}" ca
    cp "${c}/ca.pem" "${c}/certs/testdev/ca.pem"

    MNT="${d}"
    mktemp() { if [ "-d" = "${1}" ]; then echo "${MNT}"; else command mktemp "$@"; fi; }
    rmdir() { :; }
    disk_esp_attach() { echo "attached ${1}" >>"${MNT}/calls"; }
    disk_esp_detach() { echo "detached ${1}" >>"${MNT}/calls"; }

    provision_pinned_pubkey=""
    cfg_provision="${c}"
    provision_add_trust "${disk}" testdev >/dev/null 2>&1
    assert_equals 0 "$?"
    assert "cmp -s ${c}/ca.pem ${d}/provision/ca.pem"
    assert "cmp -s ${c}/certs/testdev/testdev.pem ${d}/provision/client.pem"
    assert "cmp -s ${c}/certs/testdev/testdev.key ${d}/provision/client.key"
    assert_equals 1 "$(grep -c '^detached' "${d}/calls")"

    unset -f mktemp rmdir disk_esp_attach disk_esp_detach
    rm -rf "${d}" "${c}" "${disk}"
}

test_provision_add_trust_refuses_before_touching_the_disk() {
    local c
    c="$(mktemp -d)"
    local disk
    disk="$(mktemp)"
    mkdir -p "${c}/certs/testdev" "${c}/certs/otherdev"
    provision_test_keypair "${c}/certs/testdev" testdev
    provision_test_keypair "${c}/certs/testdev" ca
    provision_test_keypair "${c}/certs/otherdev" other
    mv "${c}/certs/otherdev/other.pem" "${c}/certs/otherdev/otherdev.pem"
    mv "${c}/certs/otherdev/other.key" "${c}/certs/otherdev/otherdev.key"
    cp "${c}/certs/testdev/ca.pem" "${c}/certs/otherdev/ca.pem"

    CALLS="$(mktemp)"
    disk_esp_attach() { echo attached >>"${CALLS}"; }
    provision_pinned_pubkey=""
    cfg_provision="${c}"

    provision_add_trust "${disk}" "" >/dev/null 2>&1
    assert_equals 1 "$?" "no name"
    provision_add_trust "${disk}" "../testdev" >/dev/null 2>&1
    assert_equals 1 "$?" "a path is not a name"
    provision_add_trust "${disk}" nodev >/dev/null 2>&1
    assert_equals 1 "$?" "a device cfg-provision has no certificate for"
    provision_add_trust "${disk}" otherdev >/dev/null 2>&1
    assert_equals 1 "$?" "a certificate for another CN"
    provision_add_trust /nonexistent/disk.raw testdev >/dev/null 2>&1
    assert_equals 1 "$?" "a missing disk"
    rm "${c}/certs/testdev/ca.pem"
    provision_add_trust "${disk}" testdev >/dev/null 2>&1
    assert_equals 1 "$?" "no CA certificate"

    assert_equals "" "$(cat "${CALLS}")" "the disk is never attached"

    unset -f disk_esp_attach
    rm -rf "${c}" "${disk}" "${CALLS}"
}

test_provision_certs_refuse_before_touching_the_disk() {
    local f
    f="$(mktemp -d)"
    local disk
    disk="$(mktemp)"
    provision_test_keypair "${f}" ca
    provision_test_keypair "${f}" testdev
    provision_test_keypair "${f}" other
    echo "ssh-ed25519 AAAA" >"${f}/notcert"

    CALLS="$(mktemp)"
    disk_esp_attach() { echo attached >>"${CALLS}"; }

    provision_pinned_pubkey=""
    provision_certs "" "${f}/testdev.pem" "${f}/testdev.key" "" >/dev/null 2>&1
    assert_equals 1 "$?" "no disk"
    provision_certs /nonexistent/disk.raw "${f}/testdev.pem" "${f}/testdev.key" "" >/dev/null 2>&1
    assert_equals 1 "$?" "a missing disk"
    provision_certs "${disk}" "" "" "" >/dev/null 2>&1
    assert_equals 1 "$?" "nothing to put there"
    provision_certs "${disk}" "${f}/testdev.pem" "" "" >/dev/null 2>&1
    assert_equals 1 "$?" "a client certificate without its key"
    provision_certs "${disk}" "" "${f}/testdev.key" "" >/dev/null 2>&1
    assert_equals 1 "$?" "a key without its certificate"
    provision_certs "${disk}" "${f}/testdev.pem" "${f}/other.key" "" >/dev/null 2>&1
    assert_equals 1 "$?" "a key that does not belong to the certificate"
    provision_certs "${disk}" "${f}/notcert" "${f}/testdev.key" "" >/dev/null 2>&1
    assert_equals 1 "$?" "a client certificate that is not PEM"
    provision_certs "${disk}" "" "" "${f}/notcert" >/dev/null 2>&1
    assert_equals 1 "$?" "a CA certificate that is not PEM"
    provision_certs "${disk}" "" "" /nonexistent/ca.pem >/dev/null 2>&1
    assert_equals 1 "$?" "a missing CA certificate"
    provision_pinned_pubkey="bogus"
    provision_certs "${disk}" "" "" "" >/dev/null 2>&1
    assert_equals 1 "$?" "a malformed pin"

    assert_equals "" "$(cat "${CALLS}")" "the disk is never attached"

    provision_pinned_pubkey=""
    unset -f disk_esp_attach
    rm -rf "${f}" "${disk}" "${CALLS}"
}

provision_toml_python() {
    local p
    for p in python3 python3.14 python3.13 python3.12 python3.11; do
        if command -v "${p}" >/dev/null 2>&1 && "${p}" -c 'import tomllib' 2>/dev/null; then
            echo "${p}"
            return 0
        fi
    done
    return 1
}

test_sway_targets_use_systemd_networkd() {
    local t
    for t in gentoo-sway gentoo-sway-virt gentoo-sway-pine64 gentoo-sway-rockpro64; do
        assert_equals "systemd-networkd-dhcp" "$(net_mode_for_target gokrazy-dhcp "${t}")" "${t}"
    done
    assert_equals "gokrazy-dhcp" "$(net_mode_for_target gokrazy-dhcp gentoo-containeros)" \
        "the other targets keep gokrazy"
    assert_equals "iproute2-static" "$(net_mode_for_target iproute2-static alpine-sway)"
}

test_networkd_dhcp_makes_network_online_wait_for_the_lease() {
    local d
    d="$(mktemp -d)"
    mkdir -p "${d}/usr/lib/systemd/system"
    touch "${d}/usr/lib/systemd/system/systemd-networkd-wait-online.service"

    write_net_config "${d}" arm64 systemd-networkd-dhcp "" "" "" >/dev/null 2>&1

    assert_matches "DHCP=yes" "$(cat "${d}/etc/systemd/network/20-dhcp.network")"
    assert_equals "/usr/lib/systemd/system/systemd-networkd-wait-online.service" \
        "$(readlink "${d}/etc/systemd/system/network-online.target.wants/systemd-networkd-wait-online.service")" \
        "fetch-provision runs after network-online.target, which only waits with wait-online"
    assert_fails "test -e ${d}/etc/systemd/system/multi-user.target.wants/net-dhcp.service" \
        "gokrazy is not started next to networkd"

    rm -rf "${d}"
}

test_portage_snapshot_is_downloaded_once_and_kept_out_of_the_image() {
    local d
    d="$(mktemp -d)"
    mkdir -p "${d}/mnt" "${d}/cache"

    MNT="${d}/mnt"
    chroot() {
        shift
        case "${1}" in
        portageq) echo /var/cache/distfiles ;;
        emerge-webrsync)
            local f
            for f in gentoo-20261018.tar.xz gentoo-20261018.tar.xz.md5sum gentoo-20261018.tar.xz.gpgsig; do
                if [ -s "${MNT}/var/cache/distfiles/${f}" ]; then
                    echo "reused ${f}" >>"${MNT}/../calls"
                else
                    echo "fetched" >"${MNT}/var/cache/distfiles/${f}"
                fi
            done
            echo "$*" >>"${MNT}/../calls"
            ;;
        esac
    }

    (cd "${d}/cache" && gentoo_sync_portage_snapshot "${MNT}" 20261018)
    assert_equals 0 "$?"
    assert_equals "emerge-webrsync --keep --revert=20261018" "$(cat "${d}/calls")"
    assert "test -s ${d}/cache/gentoo-20261018.tar.xz" "the snapshot is cached for the next run"
    assert "test -s ${d}/cache/gentoo-20261018.tar.xz.gpgsig"
    assert_equals "" "$(ls -A "${MNT}/var/cache/distfiles")" "the tarball does not stay in the image"

    rm -f "${d}/calls"
    (cd "${d}/cache" && gentoo_sync_portage_snapshot "${MNT}" 20261018)
    assert_equals 3 "$(grep -c '^reused' "${d}/calls")" "the next run reuses the cached snapshot"
    assert_equals "" "$(ls -A "${MNT}/var/cache/distfiles")"

    unset -f chroot
    rm -rf "${d}"
}

stage3_fetch_fixture() {
    local d
    d="${1}"
    printf 'stage3 payload\n' >"${d}/served"
    local sum
    sum="$(shasum -a 256 "${d}/served" 2>/dev/null || sha256sum "${d}/served")"
    printf -- '-----BEGIN PGP SIGNED MESSAGE-----\nHash: SHA256\n\n# SHA256 HASH\n%s  stage3-arm64-systemd-20261018T231554Z.tar.xz\n-----BEGIN PGP SIGNATURE-----\nAAAA\n-----END PGP SIGNATURE-----\n' \
        "${sum%% *}" >"${d}/served.sha256"
    printf '# Latest as of\nstage3-arm64-systemd-20261018T231554Z.tar.xz 264113192\n' >"${d}/served.txt"
}

stage3_fetch_stub_download() {
    download() {
        echo "${1##*/}" >>"${FIXTURE}/calls"
        case "${1}" in
        *.txt) cp "${FIXTURE}/served.txt" "${2}/${1##*/}" ;;
        *.sha256) cp "${FIXTURE}/served.sha256" "${2}/${1##*/}" ;;
        *) cp "${FIXTURE}/served" "${2}/${1##*/}" ;;
        esac
    }
}

test_stage3_is_not_downloaded_again_when_it_matches_its_sha256() {
    local d
    d="$(mktemp -d)"
    mkdir -p "${d}/dl"
    stage3_fetch_fixture "${d}"
    FIXTURE="${d}"
    stage3_fetch_stub_download
    cp "${d}/served" "${d}/dl/stage3-arm64-systemd-20261018T231554Z.tar.xz"

    path="${d}/dl" gentoo_fetch_stage3 arm64 >/dev/null 2>&1
    assert_equals 0 "$?"
    assert_fails "grep -qx stage3-arm64-systemd-20261018T231554Z.tar.xz ${d}/calls" \
        "the cached stage3 is used"

    printf 'stale\n' >"${d}/dl/stage3-arm64-systemd-20261018T231554Z.tar.xz"
    rm -f "${d}/calls"
    path="${d}/dl" gentoo_fetch_stage3 arm64 >/dev/null 2>&1
    assert_equals 0 "$?"
    assert "grep -qx stage3-arm64-systemd-20261018T231554Z.tar.xz ${d}/calls" \
        "a stage3 that does not match is fetched again"
    assert_equals "stage3 payload" "$(cat "${d}/dl/stage3-arm64-systemd-20261018T231554Z.tar.xz")"

    unset -f download
    rm -rf "${d}"
}

test_stage3_download_that_does_not_match_fails() {
    local d
    d="$(mktemp -d)"
    mkdir -p "${d}/dl"
    stage3_fetch_fixture "${d}"
    FIXTURE="${d}"
    stage3_fetch_stub_download
    printf 'corrupt\n' >"${d}/served"

    (path="${d}/dl" gentoo_fetch_stage3 arm64 >/dev/null 2>&1)
    assert_equals 1 "$?"

    unset -f download
    rm -rf "${d}"
}

test_freebsd_ufs_slot_boots_its_own_partition() {
    local freebsd_rootfs_fs
    freebsd_rootfs_fs=ufs
    INCLUDE_IMAGES="freebsd" composition_load "gentoo-sway" "amd64"

    assert_equals "nomadbsd freebsd gentoo-sway" "${comp_name[*]:0:3}"
    assert_equals "ufs" "${comp_fs[1]}"
    assert_equals "rootdev=disk0p4:" "${comp_cmdline[1]}" \
        "NomadBSD is the first FreeBSD root on the disk, so the loader is told the partition"
    assert_equals "rootfs" "$(partition_name 1)" "the UFS image mounts / from /dev/gpt/rootfs"
    assert_equals "nomadbsd" "$(partition_name 0)"
    assert_equals "A503" "$(gpt_type_code "${comp_fs[1]}")"
}

test_freebsd_ufs_slot_alone_needs_no_rootdev() {
    local freebsd_rootfs_fs
    freebsd_rootfs_fs=ufs
    INCLUDE_IMAGES="freebsd" composition_load "gentoo-sway-pine64" "arm64"

    assert_equals "ufs" "${comp_fs[0]}"
    assert_equals "" "${comp_cmdline[0]}" "the loader's own walk finds the only FreeBSD root"
}

test_freebsd_zfs_slot_keeps_its_name() {
    INCLUDE_IMAGES="freebsd" composition_load "gentoo-sway-pine64" "arm64"

    assert_equals "freebsd" "$(partition_name 0)"
}

test_rootfs_filesystems_are_checked() {
    assert "rootfs_fs_check"
    assert "freebsd_rootfs_fs=ufs rootfs_fs_check"
    assert_fails "freebsd_rootfs_fs=xfs rootfs_fs_check 2>/dev/null" "FreeBSD boots ufs or zfs"
    assert_fails "linux_rootfs_fs=ext4 rootfs_fs_check 2>/dev/null"
    assert "linux_rootfs_fs=zfs rootfs_fs_check" \
        "the kernels' built-in ZFS imports the root pool without an initramfs"

    (linux_rootfs_fs=ext4 composition_load "gentoo-sway" "arm64" >/dev/null 2>&1)
    assert_equals 1 "$?" "create stops before touching a disk"
}

test_zfs_root_boots_a_dataset_without_rootwait() {
    local linux_rootfs_fs
    linux_rootfs_fs=zfs
    composition_load "gentoo-sway" "arm64"

    local i
    for i in "${!comp_name[@]}"; do
        if [ "gentoo" = "${comp_provider[$i]}" ] || [ "gentoo-kernel" = "${comp_provider[$i]}" ]; then
            assert_matches "^rw rootfstype=zfs init=" "${comp_cmdline[$i]}" "${comp_name[$i]}"
            assert_not_matches "rootwait" "${comp_cmdline[$i]}" \
                "root= names no block device for rootwait to wait for"
        fi
    done
    assert_equals "zfs" "${comp_fs[0]}"
    assert_equals "BF01" "$(gpt_type_code "${comp_fs[0]}" "${comp_provider[0]}")"

    linux_rootfs_fs=xfs
    assert_matches "^rw rootwait init=" "$(linux_cmdline_default arm64)"
}

test_zfs_root_entries_name_the_pool_and_dataset() {
    local d
    d="$(mktemp -d)"
    reexec_privileged() { :; }
    esp_mount() { :; }
    unmount_recursive() { :; }
    part_dev() { echo "/dev/test-p${1}"; }
    blkid() {
        case "${*}" in
        *"-s TYPE /dev/test-p4") echo "zfs_member" ;;
        *"-s LABEL /dev/test-p4") echo "gentoo-sway-0a1b2c3d" ;;
        *) echo "PU-${*: -1}" ;;
        esac
    }

    local linux_rootfs_fs
    linux_rootfs_fs=zfs
    composition_load "gentoo-sway" "amd64"
    install_boot_entries /dev/test-p2 "${d}" >/dev/null

    local e="${d}/loader/entries"
    assert_matches "options       root=gentoo-sway-0a1b2c3d/ROOT/default rw rootfstype=zfs " \
        "$(cat "${e}/gentoo-sway.conf")"
    assert_matches "root=gentoo-sway-0a1b2c3d/ROOT/default rw rootfstype=zfs " \
        "$(cat "${e}/gentoo-sway-x230.conf")" "the hardware kernels boot the same dataset"
    assert_fails "grep -q PARTUUID ${e}/gentoo-sway.conf"

    unset -f reexec_privileged esp_mount unmount_recursive part_dev blkid
    rm -rf "${d}"
}

test_zfs_root_pool_is_created_but_a_freebsd_pool_is_copied() {
    local calls
    calls="$(mktemp)"
    CALLS="${calls}"
    part_dev() { echo "/dev/test-p${1}"; }
    zfs_root_create() { echo "zfs_root_create ${*}" >>"${CALLS}"; }
    mkfs.xfs() { echo "mkfs.xfs ${*}" >>"${CALLS}"; }

    local linux_rootfs_fs
    linux_rootfs_fs=zfs
    INCLUDE_IMAGES="freebsd" composition_load "gentoo-sway-pine64" "arm64"
    composition_mkfs >/dev/null 2>&1

    assert_equals "zfs_root_create /dev/test-p4 gentoo-sway" "$(cat "${calls}")" \
        "only the Gentoo slot gets a new pool, the FreeBSD one is copied in"

    unset -f part_dev zfs_root_create mkfs.xfs
    rm -f "${calls}"
}

test_zfs_root_pool_lives_on_the_partition() {
    local calls
    calls="$(mktemp)"
    CALLS="${calls}"
    zfs_require() { :; }
    zpool() { echo "zpool ${*}" >>"${CALLS}"; }
    zfs() { echo "zfs ${*}" >>"${CALLS}"; }

    zfs_root_create /dev/loop0p3 gentoo-sway-virt >/dev/null 2>&1

    local create
    create="$(grep '^zpool create' "${calls}")"
    assert_matches " /dev/loop0p3$" "${create}" "the slot's partition, not the whole disk"
    assert_matches "cachefile=none" "${create}" "the build host must not remember the pool"
    assert_matches " gentoo-sway-virt-[0-9a-f]{8} " "${create}" "a random suffix keeps pool names apart"
    assert_matches "mountpoint=legacy gentoo-sway-virt-[0-9a-f]{8}/ROOT/default" "$(cat "${calls}")"
    assert_matches "^zpool export gentoo-sway-virt-[0-9a-f]{8}$" "$(tail -1 "${calls}")"

    unset -f zfs_require zpool zfs
    rm -f "${calls}"
}

test_zfs_root_is_mounted_by_its_dataset_and_exported_on_unmount() {
    local calls
    calls="$(mktemp)"
    CALLS="${calls}"
    blkid() {
        case "${*}" in
        *"-s TYPE "*) echo "zfs_member" ;;
        *"-s LABEL "*) echo "p-0a1b2c3d" ;;
        esac
    }
    zfs_require() { :; }
    zpool() {
        echo "zpool ${*}" >>"${CALLS}"
        [ "list" != "${1}" ]
    }
    mount() { echo "mount ${*}" >>"${CALLS}"; }
    umount() {
        echo "umount ${*}" >>"${CALLS}"
        : >"${CALLS}.unmounted"
    }
    findmnt() {
        case "${*}" in
        *"FSTYPE,SOURCE"*) printf 'zfs p-0a1b2c3d/ROOT/default\nproc /proc\n' ;;
        "-rno TARGET /mnt") [ ! -e "${CALLS}.unmounted" ] ;;
        esac
    }
    sync() { :; }

    rootfs_mount /dev/loop0p3 /mnt
    (unmount_recursive /mnt) >/dev/null 2>&1

    assert_equals "$(printf '%s\n' \
        "zpool list -H -o name p-0a1b2c3d" \
        "zpool import -N -o cachefile=none -d /dev/loop0p3 p-0a1b2c3d" \
        "mount -t zfs p-0a1b2c3d/ROOT/default /mnt" \
        "umount -R /mnt" \
        "zpool export p-0a1b2c3d")" "$(cat "${calls}")"

    unset -f blkid zfs_require zpool mount umount findmnt sync
    rm -f "${calls}" "${calls}.unmounted"
}

test_zfs_check_reads_the_exported_pool() {
    blkid() {
        case "${*}" in
        *"-s TYPE "*) echo "zfs_member" ;;
        *"-s LABEL "*) echo "p-0a1b2c3d" ;;
        esac
    }

    fs_check_cmd zfs_member /dev/loop0p3
    assert_equals "zdb -e -p /dev/loop0p3 -bcc p-0a1b2c3d" "${fs_check_argv[*]}" \
        "fsck.zfs is a stub, zdb verifies every block without importing"

    unset -f blkid
}

test_xfs_root_is_mounted_as_before() {
    local calls
    calls="$(mktemp)"
    CALLS="${calls}"
    blkid() { echo "xfs"; }
    mount() { echo "mount ${*}" >>"${CALLS}"; }

    rootfs_mount /dev/loop0p3 /mnt
    rootfs_mount /dev/loop0p3 /mnt xfs

    assert_equals "$(printf '%s\n' "mount -t xfs /dev/loop0p3 /mnt" "mount -t xfs /dev/loop0p3 /mnt")" \
        "$(cat "${calls}")"

    unset -f blkid mount
    rm -f "${calls}"
}

test_gentoo_root_takes_the_linux_rootfs_filesystem() {
    local t
    for t in gentoo-containeros gentoo-sway containeros-virt; do
        composition_load "${t}" "amd64"
        local i
        for i in "${!comp_name[@]}"; do
            if [ "gentoo" = "${comp_provider[$i]}" ]; then
                assert_equals "${linux_rootfs_fs}" "${comp_fs[$i]}" "${t}"
            fi
        done
    done
}

test_freebsd_zfs_falls_back_to_the_unsuffixed_release() {
    local calls
    calls="$(mktemp)"
    CALLS="${calls}"
    release_image_fetch() {
        echo "${4}" >>"${CALLS}"
        [ "${4##*-}" = latest ] && [[ "${4}" != *-zfs-* ]] && [[ "${4}" != *-ufs-* ]]
    }

    (FREEBSD_IMAGE="" freebsd_image_fetch /dl arm64 >/dev/null 2>&1)
    assert_equals 0 "$?"
    assert_equals "$(printf '%s\n' "freebsd-${freebsd_image_version}-arm64-zfs-latest" \
        "freebsd-${freebsd_image_version}-arm64-latest")" "$(cat "${calls}")"

    : >"${calls}"
    (FREEBSD_IMAGE="" freebsd_rootfs_fs=ufs freebsd_image_fetch /dl arm64 >/dev/null 2>&1)
    assert_equals 1 "$?" "the unsuffixed image is ZFS, never a stand-in for UFS"
    assert_equals "freebsd-${freebsd_image_version}-arm64-ufs-latest" "$(cat "${calls}")"

    unset -f release_image_fetch
    rm -f "${calls}"
}

test_freebsd_ufs_image_gets_no_zfs_dataset() {
    local conf
    conf="$(freebsd_vm_image_config)"

    local fs
    for fs in ufs zfs; do
        local d
        d="$(mktemp -d)"
        mkdir -p "${d}/etc" "${d}/boot"
        touch "${d}/METALOG"
        (
            pw() { :; }
            sed() { :; }
            metalog_add_data() { :; }
            DESTDIR="${d}" VMFS="${fs}" TARGET=arm64
            # shellcheck disable=SC1090
            . "${conf}"
            vm_extra_pre_umount
        ) >/dev/null 2>&1
        assert_equals 0 "$?" "${fs}"
        if [ zfs = "${fs}" ]; then
            assert_matches 'containers_dataset_enable="YES"' "$(cat "${d}/etc/rc.conf")"
            assert "test -f ${d}/usr/local/etc/rc.d/containers_dataset"
        else
            assert_fails "grep -q containers_dataset ${d}/etc/rc.conf" "a UFS root has no pool for podman's dataset"
            assert_fails "test -e ${d}/usr/local/etc/rc.d/containers_dataset"
            assert_matches 'growfs_enable="YES"' "$(cat "${d}/etc/rc.conf")"
        fi
        rm -rf "${d}"
    done
    rm -f "${conf}"
}

test_freebsd_vm_image_lists_loader_conf_once() {
    local conf
    conf="$(freebsd_vm_image_config)"

    local fs
    for fs in ufs zfs; do
        local d
        d="$(mktemp -d)"
        mkdir -p "${d}/etc" "${d}/boot"
        touch "${d}/METALOG"
        if [ zfs = "${fs}" ]; then
            echo 'zfs_load=YES' >"${d}/boot/loader.conf"
            echo './boot/loader.conf type=file uname=root gname=wheel mode=0644' >"${d}/METALOG"
        fi
        (
            pw() { :; }
            sed() { :; }
            metalog_add_data() { echo "${1} type=file" >>"${d}/METALOG"; }
            DESTDIR="${d}" VMFS="${fs}" TARGET=amd64
            # shellcheck disable=SC1090
            . "${conf}"
            vm_extra_pre_umount
        ) >/dev/null 2>&1
        assert_equals 0 "$?" "${fs}"
        assert_equals 1 "$(grep -c '^\./boot/loader\.conf ' "${d}/METALOG")" \
            "${fs}: makefs only puts what METALOG lists into the image"
        assert_matches 'console="comconsole"' "$(cat "${d}/boot/loader.conf")"
        rm -rf "${d}"
    done
    rm -f "${conf}"
}

test_freebsd_vm_image_has_a_wheel_user_sshd_and_dhcp() {
    local conf
    conf="$(freebsd_vm_image_config)"
    local d
    d="$(mktemp -d)"
    mkdir -p "${d}/etc" "${d}/boot"
    touch "${d}/METALOG"
    (
        pw() {
            case "${3}" in
            useradd)
                cat >"${d}/pw.useradd"
                echo "${*}" >>"${d}/pw.useradd"
                mkdir -p "${d}/home/tester"
                touch "${d}/home/tester/.profile"
                ;;
            usershow) echo "tester:*:1001:1002::0:0:tester:/home/tester:/bin/sh" ;;
            esac
        }
        sed() { :; }
        stat() { echo 700; }
        metalog_add_data() { :; }
        DESTDIR="${d}" VMFS=zfs TARGET=arm64 FREEBSD_VM_ROOT_PASSWORD=secret \
            FREEBSD_VM_USER=tester FREEBSD_VM_SSH_PUBKEY="ssh-ed25519 AAAA test"
        # shellcheck disable=SC1090
        . "${conf}"
        vm_extra_pre_umount
    ) >/dev/null 2>&1
    assert_equals 0 "$?"
    assert_equals "$(printf '%s\n' secret "-R ${d} useradd -n tester -G wheel -m -h 0")" \
        "$(cat "${d}/pw.useradd")" "the user gets the root password on stdin"
    assert_matches 'sshd_enable="YES"' "$(cat "${d}/etc/rc.conf")"
    assert_matches 'ifconfig_DEFAULT="DHCP' "$(cat "${d}/etc/rc.conf")"
    assert_equals "ssh-ed25519 AAAA test" "$(cat "${d}/home/tester/.ssh/authorized_keys")"
    assert_equals "$(printf '%s\n' \
        "./home/tester type=dir uid=1001 gid=1002 mode=700" \
        "./home/tester/.profile type=file uid=1001 gid=1002 mode=700" \
        "./home/tester/.ssh type=dir uid=1001 gid=1002 mode=700" \
        "./home/tester/.ssh/authorized_keys type=file uid=1001 gid=1002 mode=700")" \
        "$(LC_ALL=C sort "${d}/METALOG")" "makefs takes owners from METALOG, by id"
    rm -rf "${d}" "${conf}"
}

u_root_cpio_fixture() {
    local d
    d="${1}"
    mkdir -p "${d}/root/bbin"
    printf '#!/bin/sh\necho bb\n' >"${d}/root/bbin/bb"
    chmod 0755 "${d}/root/bbin/bb"
    ln -s bb "${d}/root/bbin/gosh"
    ln -s bb "${d}/root/bbin/netcat"
    (cd "${d}/root" && find . -mindepth 1 | sed 's|^\./||' | cpio -o -H newc --quiet) \
        >"${d}/dl/initramfs-arm64.cpio"
}

test_u_root_commands_are_checked_and_bb_is_staged() {
    command -v cpio >/dev/null || return 0
    local d
    d="$(mktemp -d)"
    mkdir -p "${d}/dl"
    u_root_cpio_fixture "${d}"

    (u_root_commands="gosh netcat" u_root_stage_bb "${d}/dl" arm64 >/dev/null 2>&1)
    assert_equals 0 "$?"
    assert_equals "$(cat "${d}/root/bbin/bb")" "$(cat "${d}/dl/u-root-bb-arm64")"
    assert "test -x ${d}/dl/u-root-bb-arm64"

    local err
    err="$( (u_root_commands="gosh vim" u_root_stage_bb "${d}/dl" arm64) 2>&1 >/dev/null)"
    assert_equals 1 "$?" "a command bb does not carry stops create before the disk is touched"
    assert_matches "has no vim" "${err}"

    rm -f "${d}/dl/u-root-bb-arm64"
    (u_root_commands="" u_root_stage_bb "${d}/dl" arm64)
    assert_fails "test -e ${d}/dl/u-root-bb-arm64" "nothing is staged without U_ROOT_COMMANDS"

    rm -rf "${d}"
}

test_u_root_commands_link_to_bb_in_local_bin() {
    local d
    d="$(mktemp -d)"
    mkdir -p "${d}/mnt/home/u" "${d}/mnt/etc"
    printf 'bb\n' >"${d}/bb"

    u_root_commands="gosh netcat bb" install_u_root_commands "${d}/mnt" u "${d}/bb"

    local bin
    bin="${d}/mnt/home/u/.local/bin"
    assert "test -x ${bin}/bb"
    assert_equals "bb" "$(readlink "${bin}/gosh")" "relative, so it resolves inside the image"
    assert_equals "bb" "$(readlink "${bin}/netcat")"
    assert "test ! -L ${bin}/bb" "bb itself is the binary, not a link to itself"
    assert_matches '.local/bin' "$(cat "${d}/mnt/etc/profile.d/local-bin.sh")"

    rm -rf "${d}"
}

test_u_root_commands_need_staged_bb() {
    local d
    d="$(mktemp -d)"
    mkdir -p "${d}/mnt/home/u"

    (u_root_commands="gosh" install_u_root_commands "${d}/mnt" u "${d}/missing" 2>/dev/null)
    assert_equals 1 "$?"

    u_root_commands="" install_u_root_commands "${d}/mnt" u "${d}/missing"
    assert_fails "test -e ${d}/mnt/home/u/.local/bin" "nothing is installed without U_ROOT_COMMANDS"

    rm -rf "${d}"
}

test_gentoo_k8s_composition_is_headless_like_containeros() {
    composition_load "gentoo-k8s" "arm64"

    assert_equals "2" "$(comp_count)" "the rootfs and rEFInd"
    assert_equals "gentoo-k8s" "${comp_name[0]}"
    assert_equals "Image-virt-arm64" "${comp_kernel[0]}"
    assert_equals "systemd-networkd-dhcp" "$(net_mode_for_target gokrazy-dhcp gentoo-k8s)" \
        "resolved announces the masters, networkd carries the hostname to DHCP"
}

test_k8s_roles_need_kubeadm_in_the_rootfs() {
    local d
    d="$(fake_rootfs_with sway)"
    write_k8s_roles "${d}"
    assert_fails "test -e ${d}/etc/systemd/system/role-k8s-master.target"
    rm -rf "${d}"
}

test_k8s_roles_hang_their_units_off_the_role_targets() {
    local d
    d="$(fake_rootfs_with kubeadm)"
    write_k8s_roles "${d}"

    local s
    s="${d}/etc/systemd/system"
    local role
    local unit
    for role in master client; do
        assert "test -f ${s}/role-k8s-${role}.target"
        for unit in kubelet.service k8s-prepare.service k8s-endpoint.timer "k8s-${role}.service"; do
            assert "test -L ${s}/role-k8s-${role}.target.wants/${unit}" "${role}: ${unit}"
        done
    done
    assert "test -L ${s}/role-k8s-master.target.wants/k8s-cilium.service"
    assert_fails "test -e ${s}/role-k8s-client.target.wants/k8s-cilium.service"
    assert_fails "test -e ${s}/multi-user.target.wants/kubelet.service" \
        "kubelet would restart forever on a node without a role"
    assert "grep -qx 'ConditionPathExists=|!/etc/kubernetes/kubelet.conf' ${s}/k8s-client.service" \
        "a node joins once"
    assert "grep -qx 'ConditionPathExists=|/var/lib/provision/k8s-attempt' ${s}/k8s-client.service" \
        "a join that died after kubeadm wrote kubelet.conf is tried again"
    assert "grep -qx 'ExecStartPre=/usr/local/sbin/k8s-endpoint' ${s}/k8s-master.service" \
        "the endpoint resolves before kubeadm needs it"
    local f
    for f in usr/local/sbin/k8s-prepare usr/local/sbin/k8s-endpoint usr/local/sbin/k8s-node \
        usr/local/sbin/k8s-cilium usr/local/lib/k8s-endpoint/mdns usr/local/lib/k8s-endpoint/dns; do
        assert "test -x ${d}/${f}" "${f}"
    done
    assert_matches "Type=_k8s-api._tcp" "$(cat "${d}/usr/local/sbin/k8s-node")"
    assert_matches 'ttl: "0s"' "$(cat "${d}/usr/local/sbin/k8s-node")"

    rm -rf "${d}"
}

k8s_endpoint_env() {
    local d
    d="${1}"
    mkdir -p "${d}/bin"
    printf 'K8S_ROLE=%s\nK8S_CLUSTER=test\nK8S_ENDPOINT=test.k8s.internal:6443\nK8S_ENDPOINT_HOST=test.k8s.internal\nK8S_ENDPOINT_METHOD=%s\nK8S_BOOTSTRAP=%s\n' \
        "${2}" "${3}" "${4:-no}" >"${d}/k8s.conf"
    printf '#!/bin/sh\necho "1.1.1.1 via 192.0.2.1 dev eth0 src 192.0.2.50 uid 0"\n' >"${d}/bin/ip"
    chmod +x "${d}/bin/ip"
}

k8s_endpoint_run() {
    local d
    d="${1}"
    PATH="${d}/bin:${PATH}" K8S_CONF="${d}/k8s.conf" K8S_ENDPOINT_LIB="${d}/root/usr/local/lib/k8s-endpoint" \
        K8S_HOSTS_FILE="${d}/hosts" sh "${d}/root/usr/local/sbin/k8s-endpoint"
}

k8s_mdns_answers() {
    printf '#!/bin/sh\ncat <<JSON\n%s\nJSON\n' "${2}" >"${1}/bin/mdns-discover"
    chmod +x "${1}/bin/mdns-discover"
}

test_k8s_endpoint_mdns_writes_the_masters_of_its_cluster() {
    provision_toml_python >/dev/null || return 0
    local d
    d="$(mktemp -d)"
    mkdir -p "${d}/root/usr/bin"
    touch "${d}/root/usr/bin/kubeadm"
    chmod +x "${d}/root/usr/bin/kubeadm"
    write_k8s_roles "${d}/root"
    k8s_endpoint_env "${d}" client mdns
    printf '127.0.0.1 localhost\n192.0.2.99 router\n' >"${d}/hosts"
    k8s_mdns_answers "${d}" '[
 {"service":"_k8s-api._tcp","address":"192.0.2.12","port":6443,"txtMap":{"cluster":"test"}},
 {"service":"_k8s-api._tcp","address":"fe80::1","port":6443,"txtMap":{"cluster":"test"}},
 {"service":"_k8s-api._tcp","address":"192.0.2.11","port":6443,"txtMap":{"cluster":"test"}},
 {"service":"_k8s-api._tcp","address":"192.0.2.11","port":6443,"txtMap":{"cluster":"test"}},
 {"service":"_k8s-api._tcp","address":"192.0.2.77","port":6443,"txtMap":{"cluster":"lab"}}
]'

    k8s_endpoint_run "${d}" >/dev/null
    assert_equals 0 "$?"
    local want
    want="$(printf '%s\n' '127.0.0.1 localhost' '192.0.2.99 router' '# k8s-endpoint test begin' \
        '192.0.2.11 test.k8s.internal' '192.0.2.12 test.k8s.internal' '# k8s-endpoint test end')"
    assert_equals "${want}" "$(cat "${d}/hosts")" "this cluster's masters only, no link-local, no duplicates"

    k8s_endpoint_run "${d}" >/dev/null
    assert_equals "${want}" "$(cat "${d}/hosts")" "a second run changes nothing"

    k8s_mdns_answers "${d}" '[{"service":"_k8s-api._tcp","address":"192.0.2.13","port":6443,"txtMap":{"cluster":"test"}}]'
    k8s_endpoint_run "${d}" >/dev/null
    assert_equals "$(printf '%s\n' '127.0.0.1 localhost' '192.0.2.99 router' '# k8s-endpoint test begin' \
        '192.0.2.13 test.k8s.internal' '# k8s-endpoint test end')" "$(cat "${d}/hosts")" "the block is replaced"

    k8s_mdns_answers "${d}" 'null'
    k8s_endpoint_run "${d}" 2>/dev/null
    assert_equals 0 "$?" "a quiet network keeps the last masters"
    assert_matches "192.0.2.13 test.k8s.internal" "$(cat "${d}/hosts")"

    rm -rf "${d}"
}

test_k8s_endpoint_mdns_without_any_master_fails() {
    provision_toml_python >/dev/null || return 0
    local d
    d="$(mktemp -d)"
    mkdir -p "${d}/root/usr/bin"
    touch "${d}/root/usr/bin/kubeadm"
    chmod +x "${d}/root/usr/bin/kubeadm"
    write_k8s_roles "${d}/root"
    k8s_endpoint_env "${d}" client mdns
    printf '127.0.0.1 localhost\n' >"${d}/hosts"
    k8s_mdns_answers "${d}" '[]'

    k8s_endpoint_run "${d}" 2>/dev/null
    assert_equals 1 "$?"
    assert_equals "127.0.0.1 localhost" "$(cat "${d}/hosts")"

    rm -rf "${d}"
}

test_k8s_endpoint_a_bootstrap_master_counts_itself_in() {
    provision_toml_python >/dev/null || return 0
    local d
    d="$(mktemp -d)"
    mkdir -p "${d}/root/usr/bin"
    touch "${d}/root/usr/bin/kubeadm"
    chmod +x "${d}/root/usr/bin/kubeadm"
    write_k8s_roles "${d}/root"
    printf '127.0.0.1 localhost\n' >"${d}/hosts"

    k8s_endpoint_env "${d}" master mdns yes
    k8s_mdns_answers "${d}" '[]'
    k8s_endpoint_run "${d}" >/dev/null
    assert_equals 0 "$?"
    assert_matches "192.0.2.50 test.k8s.internal" "$(cat "${d}/hosts")" "kubeadm init needs the name before anyone announces it"

    printf '127.0.0.1 localhost\n' >"${d}/hosts"
    k8s_endpoint_env "${d}" master mdns no
    k8s_mdns_answers "${d}" '[{"service":"_k8s-api._tcp","address":"192.0.2.11","port":6443,"txtMap":{"cluster":"test"}}]'
    k8s_endpoint_run "${d}" >/dev/null
    assert_not_matches "192.0.2.50" "$(cat "${d}/hosts")" "a joining master must not point the endpoint at itself"

    rm -rf "${d}"
}

test_k8s_endpoint_methods_are_scripts() {
    local d
    d="$(mktemp -d)"
    mkdir -p "${d}/root/usr/bin"
    touch "${d}/root/usr/bin/kubeadm"
    chmod +x "${d}/root/usr/bin/kubeadm"
    write_k8s_roles "${d}/root"

    k8s_endpoint_env "${d}" client vip
    local out
    out="$(k8s_endpoint_run "${d}" 2>&1)"
    assert_equals 1 "$?"
    assert_matches "no method vip" "${out}"

    # shellcheck disable=SC2016
    printf '#!/bin/sh\necho "vip for ${K8S_ENDPOINT_HOST}"\n' >"${d}/root/usr/local/lib/k8s-endpoint/vip"
    chmod +x "${d}/root/usr/local/lib/k8s-endpoint/vip"
    assert_equals "vip for test.k8s.internal" "$(k8s_endpoint_run "${d}")" "a new method is one more script"

    k8s_endpoint_env "${d}" client dns
    # shellcheck disable=SC2016
    printf '#!/bin/sh\n[ "${2}" = test.k8s.internal ] && echo "192.0.2.11 STREAM test.k8s.internal"\n' >"${d}/bin/getent"
    chmod +x "${d}/bin/getent"
    k8s_endpoint_run "${d}"
    assert_equals 0 "$?" "dns: the name resolves"
    printf '#!/bin/sh\nexit 2\n' >"${d}/bin/getent"
    assert_fails "k8s_endpoint_run ${d} 2>/dev/null" "dns: it does not"

    rm -rf "${d}"
}

test_provisioner_comes_from_the_bin_dir() {
    local d
    d="$(mktemp -d)"
    mkdir -p "${d}/bin/linux-arm64" "${d}/root/usr/local/sbin" "${d}/root/etc/systemd/system"
    printf '#!/bin/sh\necho "provisioner $*"\n' >"${d}/bin/linux-arm64/provisioner"
    write_provision_fetch "${d}/root" u

    provisioner_bin_dir="${d}/bin"
    install_provisioner "${d}/root" arm64
    assert_equals 0 "$?"
    assert "test -x ${d}/root/usr/local/bin/provisioner"
    assert "grep -qx 'ExecStart=/usr/local/bin/provisioner fetch %i' ${d}/root/etc/systemd/system/fetch-provision@.service" \
        "the unit runs provisioner fetch itself"
    assert_fails "test -e ${d}/root/usr/local/sbin/fetch-provision" "no shell fetch-provision next to it"
    assert_fails "test -e ${d}/root/usr/local/sbin/provision-discover"
    assert "test -L ${d}/root/etc/systemd/system/multi-user.target.wants/fetch-provision@u.service"

    assert_fails "(install_provisioner ${d}/root amd64) 2>/dev/null" "no binary for the architecture"
    provisioner_bin_dir=""
    provisioner_release_tag=""
    assert_fails "(install_provisioner ${d}/root arm64) 2>/dev/null" "neither a bin dir nor a release"

    rm -rf "${d}"
}

test_provisioner_goes_where_the_openwrt_overlay_wants_it() {
    local d
    d="$(mktemp -d)"
    mkdir -p "${d}/bin/linux-mips"
    printf '#!/bin/sh\necho "provisioner $*"\n' >"${d}/bin/linux-mips/provisioner"

    provisioner_bin_dir="${d}/bin"
    put_provisioner mips "${d}/files/usr/sbin/provisioner"
    assert_equals 0 "$?"
    assert "test -x ${d}/files/usr/sbin/provisioner"
    assert_fails "test -e ${d}/files/usr/local/bin/provisioner" "no device unit, no /usr/local"

    provisioner_bin_dir=""
    rm -rf "${d}"
}

test_openwrt_architectures_map_to_go() {
    local d
    d="$(mktemp -d)"
    printf 'CONFIG_ARCH="mips"\n' >"${d}/config"
    assert_equals mips "$(openwrt_go_arch "${d}/config")" "ath79, mips_24kc"
    printf 'CONFIG_ARCH="aarch64"\n' >"${d}/config"
    assert_equals arm64 "$(openwrt_go_arch "${d}/config")"
    printf 'CONFIG_ARCH="x86_64"\n' >"${d}/config"
    assert_equals amd64 "$(openwrt_go_arch "${d}/config")"
    printf 'CONFIG_ARCH="arm"\n' >"${d}/config"
    assert_fails "(openwrt_go_arch ${d}/config) 2>/dev/null" "no release for arm"
    rm -rf "${d}"
}
