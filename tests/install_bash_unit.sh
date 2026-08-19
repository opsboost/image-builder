#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: Björn Busse <bj.rn@baerlin.eu>
# SPDX-License-Identifier: BSD-3-Clause
#

install() {
    if [ -f "bash_unit" ]; then
        printf "bash_unit test framework exists\n"
    else
        curl -o /tmp/install.sh -sLO "$1"
        chmod +x /tmp/install.sh
        /tmp/install.sh
    fi
}

install https://raw.githubusercontent.com/pgrange/bash_unit/master/install.sh
