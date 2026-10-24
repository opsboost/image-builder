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

    assert_equals "nomadbsd gentoo-sway refind" "${comp_name[*]}"
    assert_equals "3 4 0" "${comp_part[*]}" "the Gentoo rootfs stays last, so it can grow"
    assert_equals "$((16384 + 6144))" "$(composition_disk_size_mib)"
    assert_equals "gentoo-sway" "${comp_default}" "Gentoo stays the default entry"
}

test_exclude_drops_a_slot_and_its_space() {
    EXCLUDE_IMAGES="nomadbsd" composition_load "gentoo-sway" "amd64"

    assert_equals "gentoo-sway refind" "${comp_name[*]}"
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
    echo efi > "${d}/refind_x64.efi"

    assert "refind_fetch ${d} amd64" "a staged binary needs no download"

    rm -rf "${d}"
}

test_refind_fetch_refuses_a_zip_with_the_wrong_checksum() {
    local d
    d="$(mktemp -d)"
    echo notazip > "${d}/refind-bin-${refind_version}.zip"

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
    assert_equals "A504" "$(gpt_type_code zfs)"
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

test_compare_checksums_matches_the_full_sha384() {
    local f
    f="$(mktemp)"
    printf 'hello\n' > "${f}"

    local c
    c="$(mktemp)"
    printf '1d0f284efe3edea4b9ca3bd514fa134b17eae361ccc7a1eefeff801b9bd6604e01f21f6bf249ef030599f0c218f2ba8c  %s\n' \
           "other-name" > "${c}"

    assert_equals "0" "$(compare_checksums "${c}" "${f}")" \
                  "releases name the file without -latest, so only the hash counts"

    rm -f "${f}" "${c}"
}

test_compare_checksums_rejects_a_difference_after_64_digits() {
    local f
    f="$(mktemp)"
    printf 'hello\n' > "${f}"

    local c
    c="$(mktemp)"
    printf '1d0f284efe3edea4b9ca3bd514fa134b17eae361ccc7a1eefeff801b9bd6604e%032d  %s\n' \
           0 "$(basename "${f}")" > "${c}"

    assert_equals "1" "$(compare_checksums "${c}" "${f}")" \
                  "a sha384 has 96 hex digits and all of them have to match"

    rm -f "${f}" "${c}"
}

test_compare_checksums_rejects_a_missing_checksum_file() {
    local f
    f="$(mktemp)"
    printf 'hello\n' > "${f}"

    assert_equals "1" "$(compare_checksums "${f}.sha384" "${f}" 2>/dev/null)"

    rm -f "${f}"
}

make_test_repo() {
    git init -q -b main "${1}"
    printf 'main\n' > "${1}/branch"
    git -C "${1}" add branch
    git -C "${1}" -c user.name=t -c user.email=t@t commit -q -m main
    git -C "${1}" checkout -q -b other
    printf 'other\n' > "${1}/branch"
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
    assert_equals "1" "$(grep -c 'git clone' "${SCRIPT_UNDER_TEST}")" \
                  "a bare git clone fails when an earlier run left its folder behind"
}

test_a_shared_kernel_is_copied_to_the_esp_once() {
    local d
    d="$(mktemp -d)"
    mkdir -p "${d}/esp" "${d}/src"
    echo kernel > "${d}/src/bzImage-virt-amd64-latest"
    echo loader > "${d}/src/nomadbsd-loader.efi"
    echo initrd > "${d}/src/initramfs-amd64.cpio"
    echo refind > "${d}/src/refind_x64.efi"

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

    assert_equals "nomadbsd freebsd gentoo-sway refind" "${comp_name[*]}"
    assert_equals "3 4 5 0" "${comp_part[*]}"
    assert_equals "$((16384 + 6144 + freebsd_slot_size))" "$(composition_disk_size_mib)"
    assert_equals "" "${comp_cmdline[0]}" "NomadBSD comes first, the loader's walk finds it"
    assert_equals "rootdev=zfs:zroot/ROOT/default:" "${comp_cmdline[1]}" \
                  "pinned, or its loader would boot NomadBSD's root first"
}

test_freebsd_stays_pinned_once_nomadbsd_is_excluded() {
    INCLUDE_IMAGES="freebsd" EXCLUDE_IMAGES="nomadbsd" composition_load "gentoo-sway" "amd64"

    assert_equals "freebsd gentoo-sway refind" "${comp_name[*]}"
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

test_freebsd_image_name_follows_the_arch() {
    assert_equals "freebsd-${freebsd_image_version}-arm64.img" \
                  "$(freebsd_image_file aarch64)"
    assert_equals "freebsd-${freebsd_image_version}-amd64.img" \
                  "$(freebsd_image_file x86_64)"
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

    assert_equals "nomadbsd 9front gentoo-sway refind" "${comp_name[*]}"
    assert_equals "3 4 5 0" "${comp_part[*]}"
    assert_equals "plan9" "${comp_fs[1]}"
    assert_equals "efi" "${comp_boot_type[1]}"
    assert_equals "EFI/9front/bootx64.efi" "${comp_kernel[1]}"
    assert_equals "" "${comp_cmdline[1]}" "its root is named in plan9.ini, not the load options"
    assert_equals "$((16384 + 6144 + ninefront_slot_size))" "$(composition_disk_size_mib)"
    assert_equals "gentoo-sway" "${comp_default}"
}

test_9front_composes_next_to_freebsd() {
    INCLUDE_IMAGES="freebsd 9front" composition_load "gentoo-sway" "amd64"

    assert_equals "nomadbsd freebsd 9front gentoo-sway refind" "${comp_name[*]}"
    assert_equals "rootdev=zfs:zroot/ROOT/default:" "${comp_cmdline[1]}"
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
    assert_equals "freebsd-${freebsd_image_version}-arm64-latest" "$(freebsd_release_file aarch64)"
    assert_equals "freebsd-${freebsd_image_version}-amd64-latest" "$(freebsd_release_file x86_64)"
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

    assert "test -L ${d}/etc/systemd/system/graphical.target.wants/tv-tty1@moonshine.service"
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
    assert_fails "test -e ${d}/etc/systemd/system/tv-tty1@.service"

    rm -rf "${d}"
}

test_board_sway_starts_on_tty2_on_demand() {
    local d
    d="$(fake_rootfs_with sway)"

    enable_sway_session "${d}" moonshine rockpro64

    local unit
    unit="$(cat "${d}/etc/systemd/system/autovt@tty2.service")"
    assert_matches "User=moonshine" "${unit}"
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
