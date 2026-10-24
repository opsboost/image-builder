#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: Björn Busse <bj.rn@baerlin.eu>
# SPDX-License-Identifier: BSD-3-Clause
#

TARGET_ARCH="${TARGET_ARCH:-amd64}"
WORK_DIR="${WORK_DIR:-/var/tmp/image-builder-tests}"
BOOT_TEST_TIMEOUT="${BOOT_TEST_TIMEOUT:-300}"

IMAGE_BUILDER=""
DISK_IMAGE=""
CREATE_LOG=""
BOOT_LOG=""

image_builder() {
    (
        cd "${WORK_DIR}" || exit 1
        OLDPWD="${WORK_DIR}" \
            BOOT_TEST_TIMEOUT="${BOOT_TEST_TIMEOUT}" \
            "${IMAGE_BUILDER}" "$@"
    )
}

run_logged() {
    local log
    log="${1}"
    shift

    if ! image_builder "$@" >"${log}" 2>&1; then
        tail -n 60 "${log}"
        return 1
    fi
}

setup_suite() {
    IMAGE_BUILDER="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/image-builder"
    DISK_IMAGE="${WORK_DIR}/9front-${TARGET_ARCH}.raw"
    CREATE_LOG="${WORK_DIR}/9front-${TARGET_ARCH}-create.log"
    BOOT_LOG="${WORK_DIR}/9front-${TARGET_ARCH}-boot-test.log"

    mkdir -p "${WORK_DIR}"
    rm -f "${DISK_IMAGE}" "${CREATE_LOG}" "${BOOT_LOG}"
}

test_01_9front_image_is_created() {
    assert "run_logged ${CREATE_LOG} create 9front ${TARGET_ARCH}" \
        "image-builder create 9front ${TARGET_ARCH} should succeed, see ${CREATE_LOG}"
    assert "test -s ${DISK_IMAGE}" "the disk image should exist"
}

test_02_9front_slot_is_a_plan9_partition() {
    assert_equals "C91818F9-8025-47AF-89D2-F030D7000C2C" \
        "$(sfdisk --part-type "${DISK_IMAGE}" 3 2>/dev/null)" \
        "partition 3 should carry the Plan 9 GPT type"
}

test_03_9front_boots_to_a_shell() {
    assert "run_logged ${BOOT_LOG} boot-test 9front ${TARGET_ARCH}" \
        "image-builder boot-test 9front ${TARGET_ARCH} should reach a shell prompt, see ${BOOT_LOG}"
}
