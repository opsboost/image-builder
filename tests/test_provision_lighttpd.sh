#!/usr/bin/env bash
#
# End-to-end tests for first-boot provisioning: provisioner seals fake device
# files, cfg-provision's router/ lighttpd config and CGI serve them over mutual
# TLS, with the same mod_wolfssl the router uses, and provisioner fetch
# fetches, opens and applies them. ROUTER_IMPL=go serves them with
# provisioner router instead of lighttpd. provisioner comes from
# PROVISIONER_BIN.
#
# They write to /etc, /www-provision and /usr/local and create users, so they
# only run in a throwaway container: make test-provision
#
# SPDX-FileCopyrightText: Björn Busse <bj.rn@baerlin.eu>
# SPDX-License-Identifier: BSD-3-Clause
#
# shellcheck disable=SC2034,SC2154

setup_suite() {
    if [ ! -f /run/.containerenv ] && [ ! -f /.dockerenv ]; then
        echo "test_provision_lighttpd: not in a container, run make test-provision" >&2
        exit 1
    fi

    SCRIPT_UNDER_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/image-builder"
    CFG_PROVISION="${CFG_PROVISION:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/cfg-provision}"
    CFG_SERVICES="${CFG_SERVICES:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/cfg-services}"
    ROUTER="${CFG_PROVISION}/router"
    local f
    for f in lighttpd openssl curl python3 useradd; do
        command -v "${f}" >/dev/null 2>&1 || {
            echo "test_provision_lighttpd: ${f} is missing" >&2
            exit 1
        }
    done
    for f in etc/lighttpd/lighttpd.conf www-provision/cgi-bin/provision; do
        [ -f "${ROUTER}/${f}" ] || {
            echo "test_provision_lighttpd: no ${f} in ${ROUTER}" >&2
            exit 1
        }
    done
    [ -x "${PROVISIONER_BIN:-}/provisioner" ] ||
        {
            echo "test_provision_lighttpd: no provisioner in PROVISIONER_BIN" >&2
            exit 1
        }

    W="$(mktemp -d)"
    umask 022
    FETCH=(/usr/local/bin/provisioner fetch)

    pki_ca "${W}/ca" "/CN=provision test CA"
    pki_ca "${W}/other-ca" "/CN=another CA"
    pki_cert "${W}/server" "${W}/ca" "/CN=provision.test" serverAuth "subjectAltName=IP:127.0.0.1,DNS:localhost"
    pki_cert "${W}/testdev" "${W}/ca" "/CN=testdev" clientAuth
    pki_cert "${W}/nobody" "${W}/ca" "/CN=nobody" clientAuth
    pki_cert "${W}/timedev" "${W}/ca" "/CN=timedev" clientAuth
    pki_cert "${W}/hostdev" "${W}/ca" "/CN=hostdev" clientAuth
    pki_cert "${W}/multidev" "${W}/ca" "/CN=multidev" clientAuth
    pki_cert "${W}/plaindev" "${W}/ca" "/CN=plaindev" clientAuth
    pki_cert "${W}/roguedev" "${W}/ca" "/CN=roguedev" clientAuth
    pki_cert "${W}/imposterdev" "${W}/ca" "/CN=imposterdev" clientAuth
    pki_cert "${W}/swapdev" "${W}/ca" "/CN=swapdev" clientAuth
    pki_cert "${W}/bothdev" "${W}/ca" "/CN=bothdev" clientAuth
    pki_cert "${W}/k8smaster" "${W}/ca" "/CN=k8smaster" clientAuth
    pki_cert "${W}/k8sclient" "${W}/ca" "/CN=k8sclient" clientAuth
    pki_cert "${W}/unitdev" "${W}/ca" "/CN=unitdev" clientAuth
    pki_cert "${W}/lingerdev" "${W}/ca" "/CN=lingerdev" clientAuth
    pki_cert "${W}/cfg-provision" "${W}/ca" "/CN=cfg-provision" clientAuth
    pki_cert "${W}/rogue-signer" "${W}/other-ca" "/CN=cfg-provision" clientAuth
    pki_cert "${W}/slash" "${W}/ca" "/CN=..\/provision\/testdev" clientAuth
    pki_cert "${W}/foreign" "${W}/other-ca" "/CN=testdev" clientAuth
    PIN="sha256//$(openssl pkey -in "${W}/server.key" -pubout -outform der | openssl dgst -sha256 -binary | base64)"

    WG_KEY="$(openssl rand -base64 32)"
    WG_PEER="$(openssl rand -base64 32)"
    DEVICE_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeKeyForProvisioningTests provision-test"

    mkdir -p /etc/lighttpd /etc/provision /www-provision/cgi-bin /var/log/lighttpd
    install -m 0644 "${W}/server.pem" /etc/lighttpd/server.pem
    install -m 0600 "${W}/server.key" /etc/lighttpd/server.key
    install -m 0640 -o root -g www-data "${W}/ca.pem" /etc/provision/ca.pem
    install -m 0755 "${ROUTER}/www-provision/cgi-bin/provision" /www-provision/cgi-bin/provision
    cat >"${W}/testdev.toml" <<EOF
[system]
user = "newuser"
hostname = "testdev"
roles = ["tv", "wg"]

[ssh]
authorized_keys = ["${DEVICE_KEY}"]

[wg]
private_key = "${WG_KEY}"
address = ["10.99.0.4/32"]

[[wg.peer]]
public_key = "${WG_PEER}"
endpoint = "198.51.100.1:51820"
allowed_ips = ["10.99.0.0/24"]
persistent_keepalive = 25
EOF
    printf '[ssh]\nauthorized_keys = ["%s"]\n' "${DEVICE_KEY}" >"${W}/timedev.toml"
    printf '[system]\nhostname = "hostdev"\n' >"${W}/hostdev.toml"
    printf '[system]\nuser = "lingered"\n' >"${W}/lingerdev.toml"
    cat >"${W}/multidev.toml" <<EOF
[system]
timezone = "Test/Zone"

[users.multi]
shell = "bash"
authorized_keys = ["${DEVICE_KEY}"]
git-clone = ["https://example.invalid/r/dot.git"]

[users.multi.env]
EDITOR = "vim"
GREETING = "hello world"

[users.newbie]
authorized_keys = ["${DEVICE_KEY}"]
EOF
    printf '[ssh]\nauthorized_keys = ["%s"]\n' "${DEVICE_KEY}" >"${W}/plaindev.toml"
    install -m 0640 -o root -g www-data "${W}/plaindev.toml" /etc/provision/plaindev.toml

    K8S_HASH="sha256:$(openssl pkey -in "${W}/other-ca.key" -pubout -outform der | openssl dgst -sha256 -hex | sed 's/.* //')"
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "${W}/sa.key" 2>/dev/null
    openssl pkey -in "${W}/sa.key" -pubout -out "${W}/sa.pub"
    {
        printf '[system]\nroles = ["k8s-master"]\n\n[k8s]\ncluster = "test"\n'
        printf 'token = "abcdef.0123456789abcdef"\nca_cert_hash = "%s"\nbootstrap = true\n\n[k8s.pki]\n' "${K8S_HASH}"
        local k f
        for k in ca_crt:other-ca.pem ca_key:other-ca.key front_proxy_ca_crt:other-ca.pem front_proxy_ca_key:other-ca.key \
            etcd_ca_crt:other-ca.pem etcd_ca_key:other-ca.key sa_key:sa.key sa_pub:sa.pub; do
            f="${k#*:}"
            printf '%s = """\n%s\n"""\n' "${k%%:*}" "$(cat "${W}/${f}")"
        done
    } >"${W}/k8smaster.toml"
    printf '[system]\nroles = ["k8s-client"]\n\n[k8s]\ncluster = "test"\ntoken = "abcdef.0123456789abcdef"\nca_cert_hash = "%s"\n' \
        "${K8S_HASH}" >"${W}/k8sclient.toml"

    cat >"${W}/unitdev.toml" <<'EOF'
[systemd-system."provision-hello.service"]
content = """
[Service]
Type=oneshot
ExecStart=/bin/true

[Install]
WantedBy=multi-user.target
"""

[systemd-system."ssh.service.d/10-provision.conf"]
content = """
[Service]
Environment=PROVISIONED=1
"""

[systemd-user."provision-hello.service"]
content = """
[Service]
ExecStart=/bin/true

[Install]
WantedBy=default.target
"""

[users.unituser.systemd."mine.service"]
content = """
[Service]
ExecStart=/bin/true

[Install]
WantedBy=default.target
"""

[users.unituser.systemd."mine.service.d/10-env.conf"]
content = """
[Service]
Environment=MINE=1
"""
EOF

    local name
    mkdir -p "${W}/certs/cfg-provision" "${W}/plain"
    cp "${W}/cfg-provision.pem" "${W}/cfg-provision.key" "${W}/certs/cfg-provision/"
    cp "${W}/ca.pem" "${W}/certs/cfg-provision/ca.pem"
    for name in testdev timedev hostdev multidev bothdev k8smaster k8sclient unitdev lingerdev; do
        mkdir -p "${W}/certs/${name}"
        cp "${W}/${name}.pem" "${W}/${name}.key" "${W}/ca.pem" "${W}/certs/${name}/"
        cp "${W}/${name}.toml" "${W}/plain/${name}.toml" 2>/dev/null ||
            printf '[ssh]\nauthorized_keys = ["%s"]\n' "${DEVICE_KEY}" >"${W}/plain/${name}.toml"
    done
    PROVISIONER_ENV=/dev/null PROVISIONER_DATA="${W}" "${PROVISIONER_BIN}/provisioner" seal >/dev/null ||
        {
            echo "test_provision_lighttpd: provisioner seal failed" >&2
            exit 1
        }
    for name in testdev timedev hostdev multidev bothdev k8smaster k8sclient unitdev lingerdev; do
        install -m 0640 -o root -g www-data "${W}/devices/${name}.cms" "/etc/provision/${name}.cms"
    done
    install -m 0640 -o root -g www-data "${W}/plain/bothdev.toml" /etc/provision/bothdev.toml
    install -m 0640 -o root -g www-data "${W}/devices/testdev.cms" /etc/provision/swapdev.cms
    seal_with "${W}/rogue-signer" "${W}/roguedev" "${W}/plaindev.toml" /etc/provision/roguedev.cms
    seal_with "${W}/testdev" "${W}/imposterdev" "${W}/plaindev.toml" /etc/provision/imposterdev.cms
    chown root:www-data /etc/provision/*.cms
    chmod 0640 /etc/provision/*.cms
    getent group wheel >/dev/null || groupadd wheel
    mkdir -p /usr/share/zoneinfo/Test && touch /usr/share/zoneinfo/Test/Zone
    chown root:www-data /etc/provision
    chmod 0750 /etc/provision

    sed -e 's#^server.username .*#server.username      = "www-data"#' \
        -e 's#^server.pid-file .*#server.pid-file      = "'"${W}"'/lighttpd.pid"#' \
        "${ROUTER}/etc/lighttpd/lighttpd.conf" >"${W}/lighttpd.conf"
    if [ "${ROUTER_IMPL:-}" = go ]; then
        "${PROVISIONER_BIN}/provisioner" router -listen :8443 -cert /etc/lighttpd/server.pem \
            -key /etc/lighttpd/server.key -ca /etc/provision/ca.pem -dir /etc/provision 2>"${W}/router.log" &
        echo $! >"${W}/router.pid"
    else
        lighttpd -f "${W}/lighttpd.conf" || {
            echo "test_provision_lighttpd: lighttpd did not start" >&2
            exit 1
        }
    fi
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        curl -sk -o /dev/null https://127.0.0.1:8443/ 2>/dev/null
        [ $? -ne 7 ] && break
        sleep 0.5
    done
}

teardown_suite() {
    [ -f "${W}/lighttpd.pid" ] && kill "$(cat "${W}/lighttpd.pid")"
    [ -f "${W}/router.pid" ] && kill "$(cat "${W}/router.pid")"
    rm -rf "${W}"
}

pki_ca() {
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-384 -nodes -sha384 -days 1 \
        -subj "${2}" -keyout "${1}.key" -out "${1}.pem" \
        -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
}

pki_cert() {
    local ext
    ext="$(mktemp)"
    printf 'basicConstraints=CA:FALSE\nkeyUsage=digitalSignature,nonRepudiation,keyEncipherment\nextendedKeyUsage=%s\n' "${4}" >"${ext}"
    [ -n "${5:-}" ] && printf '%s\n' "${5}" >>"${ext}"
    openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
        -subj "${3}" -keyout "${1}.key" -out "${1}.csr" 2>/dev/null
    openssl x509 -req -in "${1}.csr" -CA "${2}.pem" -CAkey "${2}.key" -days 1 -extfile "${ext}" \
        -out "${1}.pem" 2>/dev/null
    rm -f "${ext}" "${1}.csr"
}

seal_with() {
    local signed
    signed="$(mktemp)"
    openssl cms -sign -binary -nodetach -md sha256 -in "${3}" -signer "${1}.pem" -inkey "${1}.key" \
        -outform DER -out "${signed}"
    openssl cms -encrypt -binary -aes-256-gcm -in "${signed}" -outform PEM -out "${4}" "${2}.pem"
    rm -f "${signed}"
}

fetch() {
    local cert
    cert="${1}"
    shift
    curl -sS --max-time 10 --proto "=https" --cacert "${W}/ca.pem" --pinnedpubkey "${PIN}" \
        ${cert:+--cert "${W}/${cert}.pem" --key "${W}/${cert}.key"} "$@" \
        https://127.0.0.1:8443/cgi-bin/provision
}

test_lighttpd_loads_the_router_config() {
    [ "${ROUTER_IMPL:-}" = go ] && return 0
    assert "lighttpd -tt -f ${W}/lighttpd.conf"
}

test_a_device_gets_its_own_file() {
    assert_equals "$(cat /etc/provision/testdev.cms)" "$(fetch testdev)"
}

test_a_sealed_file_wins_over_a_plain_one() {
    assert_equals "$(cat /etc/provision/bothdev.cms)" "$(fetch bothdev)"
}

test_a_device_without_a_file_gets_nothing() {
    assert_equals "200 0" "$(fetch nobody -o /dev/null -w '%{http_code} %{size_download}')"
}

test_no_client_certificate_is_refused() {
    assert_fails "fetch '' -o /dev/null"
}

test_a_certificate_from_another_ca_is_refused() {
    assert_fails "fetch foreign -o /dev/null"
}

test_a_cn_that_is_not_a_name_is_forbidden() {
    assert_equals 403 "$(fetch slash -o /dev/null -w '%{http_code}')" \
        "a CN with a slash must not reach the file system"
}

test_a_wrong_pin_is_refused_by_the_device() {
    assert_fails "curl -sS --max-time 10 --cacert ${W}/ca.pem --pinnedpubkey sha256//AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= --cert ${W}/testdev.pem --key ${W}/testdev.key -o /dev/null https://127.0.0.1:8443/cgi-bin/provision"
}

install_fetch_provision() {
    local root
    root="${W}/root"
    mkdir -p "${root}/usr/local/sbin" "${root}/etc/systemd/system"
    (
        # shellcheck disable=SC1090
        source <(sed '/^args=("\$@")$/,$d' "${SCRIPT_UNDER_TEST}")
        log_level=quiet
        cfg_services="${CFG_SERVICES}"
        write_provision_fetch "${root}" moonshine
    )
    install -m 0755 "${root}/usr/local/sbin/provision-git-clone" /usr/local/sbin/
    install -D -m 0644 "${root}/etc/profile.d/provision-env.sh" /etc/profile.d/provision-env.sh
    mkdir -p /etc/systemd/system /etc/systemd/network
    cp -a "${root}/etc/systemd/system/." /etc/systemd/system/
    printf '[Unit]\nDescription=Role tv\n' >/etc/systemd/system/role-tv.target
    install -m 0755 "${PROVISIONER_BIN}/provisioner" /usr/local/bin/provisioner
}

stub() {
    mkdir -p "${W}/bin"
    printf '#!/bin/sh\n%s\n' "${2}" >"${W}/bin/${1}"
    chmod 0755 "${W}/bin/${1}"
}

test_fetch_provision_finds_the_server_and_applies_the_file() {
    install_fetch_provision
    id moonshine >/dev/null 2>&1 || useradd -m -U moonshine
    getent group systemd-network >/dev/null || groupadd systemd-network
    mkdir -p "${W}/esp/provision"
    cp "${W}/ca.pem" "${W}/esp/provision/ca.pem"
    cp "${W}/testdev.pem" "${W}/esp/provision/client.pem"
    cp "${W}/testdev.key" "${W}/esp/provision/client.key"
    printf '%s\n' "${PIN}" >"${W}/esp/provision/pinnedpubkey"

    stub mdns-discover "echo \"\${MDNS_SERVICE_FILTER}\" >>${W}/mdns; echo '[{\"service\":\"_provision._tcp\",\"address\":\"127.0.0.1\",\"port\":8443}]'"
    stub hostnamectl "echo \"\$*\" >>${W}/hostnamectl"
    stub systemctl "echo \"\$*\" >>${W}/systemctl"
    stub networkctl "echo \"\$*\" >>${W}/networkctl"

    local out
    out="$(PATH="${W}/bin:${PATH}" PROVISION_ESP="${W}/esp" "${FETCH[@]}" moonshine 2>&1)"
    assert_equals 0 "$?" "${out}"

    assert_equals "_provision._tcp" "$(cat "${W}/mdns")" "the server is looked up over mDNS"
    assert_fails "id moonshine" "the image user is renamed"
    assert "id newuser"
    assert "test -d /home/newuser"
    assert "grep -qxF '${DEVICE_KEY}' /home/newuser/.ssh/authorized_keys"
    assert_equals "set-hostname testdev" "$(cat "${W}/hostnamectl")"
    assert "grep -qx 'enable role-tv.target' ${W}/systemctl"
    assert "grep -qx 'enable role-wg.target' ${W}/systemctl"
    assert "test -L /etc/systemd/system/multi-user.target.wants/fetch-provision@newuser.service"
    assert_fails "test -e /etc/systemd/system/multi-user.target.wants/fetch-provision@moonshine.service"
    assert "grep -qx 'PrivateKey=${WG_KEY}' /etc/systemd/network/wg0.netdev"
    assert "grep -qx 'ActivationPolicy=manual' /etc/systemd/network/wg0.network"
    assert_equals "root:systemd-network 640" "$(stat -c '%U:%G %a' /etc/systemd/network/wg0.netdev)"
}

test_fetch_provision_without_a_client_certificate_does_nothing() {
    install_fetch_provision
    id nocert >/dev/null 2>&1 || useradd -m -U nocert
    mkdir -p "${W}/empty-esp/provision"
    stub mdns-discover "echo called >>${W}/mdns-nocert; echo '[]'"

    local out
    out="$(PATH="${W}/bin:${PATH}" PROVISION_ESP="${W}/empty-esp" "${FETCH[@]}" nocert 2>&1)"
    assert_equals 0 "$?"
    assert_matches "no client certificate" "${out}"
    assert_fails "test -e ${W}/mdns-nocert" "no certificate, no need to look for a server"
}

timedev_esp() {
    mkdir -p "${W}/time-esp/provision"
    cp "${W}/ca.pem" "${W}/time-esp/provision/ca.pem"
    cp "${W}/timedev.pem" "${W}/time-esp/provision/client.pem"
    cp "${W}/timedev.key" "${W}/time-esp/provision/client.key"
    printf '%s\n' "${PIN}" >"${W}/time-esp/provision/pinnedpubkey"
    stub mdns-discover "echo '[{\"address\":\"127.0.0.1\",\"port\":8443}]'"
    stub hostnamectl "true"
    stub systemctl "true"
    stub networkctl "true"
}

test_fetch_provision_waits_for_the_clock() {
    install_fetch_provision
    id timeuser >/dev/null 2>&1 || useradd -m -U timeuser
    timedev_esp
    rm -f "${W}/timedatectl"
    stub timedatectl "echo x >>${W}/timedatectl; [ \$(wc -l <${W}/timedatectl) -ge 3 ] && echo yes || echo no"

    local out
    out="$(PATH="${W}/bin:${PATH}" PROVISION_ESP="${W}/time-esp" "${FETCH[@]}" timeuser 2>&1)"
    assert_equals 0 "$?" "${out}"
    assert_equals 3 "$(wc -l <"${W}/timedatectl")" "asked until NTP was synchronised"
    assert_not_matches "not synchronised" "${out}"
    assert "grep -qxF '${DEVICE_KEY}' /home/timeuser/.ssh/authorized_keys"
}

test_fetch_provision_does_not_wait_forever_for_the_clock() {
    install_fetch_provision
    id timeuser >/dev/null 2>&1 || useradd -m -U timeuser
    timedev_esp
    stub timedatectl "echo no"

    local out
    out="$(PATH="${W}/bin:${PATH}" PROVISION_ESP="${W}/time-esp" PROVISION_TIME_WAIT=2 \
        "${FETCH[@]}" timeuser 2>&1)"
    assert_equals 0 "$?" "${out}"
    assert_matches "clock not synchronised after 2s" "${out}"
    assert "grep -qxF '${DEVICE_KEY}' /home/timeuser/.ssh/authorized_keys"
}

test_a_new_hostname_reconfigures_the_dhcp_links() {
    install_fetch_provision
    id hostuser >/dev/null 2>&1 || useradd -m -U hostuser
    mkdir -p "${W}/host-esp/provision"
    cp "${W}/ca.pem" "${W}/host-esp/provision/ca.pem"
    cp "${W}/hostdev.pem" "${W}/host-esp/provision/client.pem"
    cp "${W}/hostdev.key" "${W}/host-esp/provision/client.key"
    printf '%s\n' "${PIN}" >"${W}/host-esp/provision/pinnedpubkey"
    stub mdns-discover "echo '[{\"address\":\"127.0.0.1\",\"port\":8443}]'"
    stub hostnamectl "echo \"\$*\" >>${W}/host-hostnamectl"
    stub systemctl "true"
    cat >"${W}/bin/networkctl" <<EOF
#!/bin/sh
if [ "\${1}" = list ]; then
    printf '%s\\n' '  1 lo     loopback carrier  unmanaged' '  2 enp0s1 ether    routable configured' \\
        '  3 wlan0  wlan     routable configured' '  4 eth9   ether    off      unmanaged' \\
        '  5 wg0    wireguard routable configured'
else
    echo "\$*" >>${W}/host-networkctl
fi
EOF
    chmod 0755 "${W}/bin/networkctl"

    stub uname "echo old-name"
    local out
    out="$(PATH="${W}/bin:${PATH}" PROVISION_ESP="${W}/host-esp" "${FETCH[@]}" hostuser 2>&1)"
    assert_equals 0 "$?" "${out}"
    assert_equals "set-hostname hostdev" "$(cat "${W}/host-hostnamectl")"
    assert_equals "$(printf '%s\n' "reconfigure enp0s1" "reconfigure wlan0")" "$(cat "${W}/host-networkctl")" \
        "only managed Ethernet and Wi-Fi links, not lo, unmanaged links or wg0"

    rm -f "${W}/host-networkctl"
    stub uname "echo hostdev"
    PATH="${W}/bin:${PATH}" PROVISION_ESP="${W}/host-esp" "${FETCH[@]}" hostuser >/dev/null 2>&1
    assert_fails "test -e ${W}/host-networkctl" "an unchanged hostname leaves the network alone"
}

test_a_user_in_session_with_a_running_unit_and_linger_is_renamed() {
    install_fetch_provision
    id lingerer >/dev/null 2>&1 || useradd -m -U lingerer
    mkdir -p /var/lib/systemd/linger "${W}/linger-esp/provision" /etc/systemd/system/autovt@tty9.service.d
    : >/var/lib/systemd/linger/lingerer
    printf '[Service]\nUser=lingerer\n' >/etc/systemd/system/autovt@tty9.service.d/user.conf
    cp "${W}/ca.pem" "${W}/linger-esp/provision/ca.pem"
    cp "${W}/lingerdev.pem" "${W}/linger-esp/provision/client.pem"
    cp "${W}/lingerdev.key" "${W}/linger-esp/provision/client.key"
    printf '%s\n' "${PIN}" >"${W}/linger-esp/provision/pinnedpubkey"
    rm -f "${W}/linger.pid"
    setsid -f sh -c "echo \$\$ >${W}/linger.pid; exec setpriv --reuid=lingerer --regid=lingerer --clear-groups sleep 600"
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        [ -s "${W}/linger.pid" ] && break
        sleep 0.1
    done
    local uid
    uid="$(id -u lingerer)"
    stub mdns-discover "echo '[{\"address\":\"127.0.0.1\",\"port\":8443}]'"
    cat >"${W}/bin/systemctl" <<EOF
#!/bin/sh
echo "\$*" >>${W}/linger-systemctl
[ "\$*" = "show -P ActiveState autovt@tty9.service" ] && echo active
exit 0
EOF
    cat >"${W}/bin/loginctl" <<EOF
#!/bin/sh
echo "\$*" >>${W}/linger-loginctl
if [ "\$*" = "terminate-user lingerer" ]; then
    kill \$(cat ${W}/linger.pid)
fi
EOF
    cat >"${W}/bin/usermod" <<EOF
#!/bin/sh
for user; do :; done
if [ "\${user}" = lingerer ] && kill -0 \$(cat ${W}/linger.pid) 2>/dev/null; then
    echo "usermod: user lingerer is currently used by process \$(cat ${W}/linger.pid)" >&2
    exit 8
fi
exec $(command -v usermod) "\$@"
EOF
    chmod 0755 "${W}/bin/systemctl" "${W}/bin/loginctl" "${W}/bin/usermod"

    local out
    out="$(PATH="${W}/bin:${PATH}" PROVISION_ESP="${W}/linger-esp" "${FETCH[@]}" lingerer 2>&1)"
    assert_equals 0 "$?" "${out}"
    assert "id lingered"
    assert_fails "id lingerer"
    assert_equals "$(printf '%s\n' "terminate-user lingerer" "disable-linger lingerer" "enable-linger lingered")" \
        "$(cat "${W}/linger-loginctl")" "the sessions end and linger moves to the new name"
    assert_equals "$(printf '%s\n' "stop autovt@tty9.service" "stop user@${uid}.service" "--no-block start autovt@tty9.service")" \
        "$(awk '/^stop |start /' "${W}/linger-systemctl")" "the unit and the user manager stop for the rename and the unit starts again"
    assert "grep -qx 'User=lingered' /etc/systemd/system/autovt@tty9.service.d/user.conf"
    rm -rf /etc/systemd/system/autovt@tty9.service.d
}

test_users_shells_environment_and_clones_are_provisioned() {
    install_fetch_provision
    id multi >/dev/null 2>&1 || useradd -m -U multi
    mkdir -p "${W}/multi-esp/provision"
    cp "${W}/ca.pem" "${W}/multi-esp/provision/ca.pem"
    cp "${W}/multidev.pem" "${W}/multi-esp/provision/client.pem"
    cp "${W}/multidev.key" "${W}/multi-esp/provision/client.key"
    printf '%s\n' "${PIN}" >"${W}/multi-esp/provision/pinnedpubkey"
    stub mdns-discover "echo '[{\"address\":\"127.0.0.1\",\"port\":8443}]'"
    stub timedatectl "echo \"\$*\" >>${W}/multi-timedatectl; [ \"\${1}\" = show ] && echo yes; true"
    stub systemctl "echo \"\$*\" >>${W}/multi-systemctl"
    stub networkctl "true"
    rm -f /var/lib/provision/git-clone

    local out
    out="$(PATH="${W}/bin:${PATH}" PROVISION_ESP="${W}/multi-esp" "${FETCH[@]}" multi 2>&1)"
    assert_equals 0 "$?" "${out}"

    assert "grep -qx 'set-timezone Test/Zone' ${W}/multi-timedatectl"
    assert_equals "/bin/bash" "$(getent passwd multi | cut -d: -f7)" "bash looked up in /etc/shells"
    assert_equals "$(printf 'EDITOR=vim\nGREETING=hello world')" \
        "$(cat /home/multi/.config/environment.d/50-provision.conf)"
    assert_equals "multi:multi" "$(stat -c %U:%G /home/multi/.config/environment.d/50-provision.conf)"
    assert "grep -qxF '${DEVICE_KEY}' /home/multi/.ssh/authorized_keys"
    assert_equals "$(printf 'multi\thttps://example.invalid/r/dot.git\t~/src/dot\t')" "$(cat /var/lib/provision/git-clone)"
    assert "grep -qx -- '--no-block start provision-git-clone.service' ${W}/multi-systemctl" \
        "clones run in their own unit, not before logins"

    assert "id newbie" "a user the device does not have is created"
    assert "id -nG newbie | grep -qw wheel" "in wheel, which ssh and su require"
    assert "test -d /home/newbie"
    assert "grep -qxF '${DEVICE_KEY}' /home/newbie/.ssh/authorized_keys"
}

test_a_login_shell_sees_the_provisioned_environment() {
    install_fetch_provision
    mkdir -p "${W}/envhome/.config/environment.d"
    printf 'EDITOR=vim\nGREETING=hello world\n# a comment\n' >"${W}/envhome/.config/environment.d/50-provision.conf"

    assert_equals "vim|hello world" \
        "$(HOME="${W}/envhome" sh -c '. /etc/profile.d/provision-env.sh; echo "${EDITOR}|${GREETING}"')"
}

test_queued_repositories_are_cloned_shallow_as_their_user() {
    install_fetch_provision
    id cloner >/dev/null 2>&1 || useradd -m -U cloner
    local repo
    repo="${W}/upstream"
    git init -q -b main "${repo}"
    git -C "${repo}" -c user.name=t -c user.email=t@t commit -q --allow-empty -m one
    git -C "${repo}" -c user.name=t -c user.email=t@t commit -q --allow-empty -m two
    chown -R cloner:cloner "${repo}"
    chmod 755 "${W}"
    runuser -u cloner -- mkdir -p /home/cloner/src/kept
    printf 'cloner\tfile://%s\t~/src/dot\t\ncloner\tfile://%s\t~/src/kept\t\ncloner\tfile://%s/missing\t~/src/gone\t\n' \
        "${repo}" "${repo}" "${W}" >"${W}/queue"

    local out
    out="$(PROVISION_GIT_CLONE_LIST="${W}/queue" /usr/local/sbin/provision-git-clone 2>&1)"
    assert_equals 1 "$?" "one clone fails"
    assert "test -f /home/cloner/src/dot/.git/shallow" "a shallow clone"
    assert_equals "cloner" "$(stat -c %U /home/cloner/src/dot)"
    assert_matches "src/kept exists, leaving it" "${out}"
    assert_equals "$(printf 'cloner\tfile://%s/missing\t/home/cloner/src/gone\t' "${W}")" "$(cat "${W}/queue")" \
        "only the failed clone stays queued"
}

device_esp() {
    rm -rf "${W}/${1}-esp"
    mkdir -p "${W}/${1}-esp/provision"
    [ "${2:-}" = noca ] || cp "${W}/ca.pem" "${W}/${1}-esp/provision/ca.pem"
    cp "${W}/${1}.pem" "${W}/${1}-esp/provision/client.pem"
    cp "${W}/${1}.key" "${W}/${1}-esp/provision/client.key"
    printf '%s\n' "${PIN}" >"${W}/${1}-esp/provision/pinnedpubkey"
    stub mdns-discover "echo '[{\"address\":\"127.0.0.1\",\"port\":8443}]'"
    stub timedatectl "echo yes"
    stub hostnamectl "true"
    stub systemctl "true"
    stub networkctl "true"
}

provision_as() {
    id "${2}" >/dev/null 2>&1 || useradd -m -U "${2}"
    PATH="${W}/bin:${PATH}" PROVISION_ESP="${W}/${1}-esp" "${FETCH[@]}" "${2}" 2>&1
}

test_a_plain_file_is_refused_when_the_esp_has_a_ca() {
    install_fetch_provision
    device_esp plaindev

    local out
    out="$(provision_as plaindev plainuser)"
    assert_equals 1 "$?" "${out}"
    assert_matches "not sealed, refusing it" "${out}"
    assert_fails "test -e /home/plainuser/.ssh/authorized_keys"
}

test_a_plain_file_is_taken_without_a_ca_on_the_esp() {
    install_fetch_provision
    device_esp plaindev noca

    local out
    out="$(provision_as plaindev plainnoca)"
    assert_equals 0 "$?" "${out}"
    assert "grep -qxF '${DEVICE_KEY}' /home/plainnoca/.ssh/authorized_keys"
}

test_a_file_signed_under_another_ca_is_refused() {
    install_fetch_provision
    device_esp roguedev

    local out
    out="$(provision_as roguedev rogueuser)"
    assert_equals 1 "$?" "${out}"
    assert_matches "not signed by a certificate from provision/ca.pem" "${out}"
    assert_fails "test -e /home/rogueuser/.ssh/authorized_keys"
}

test_a_file_signed_by_another_certificate_of_the_ca_is_refused() {
    install_fetch_provision
    device_esp imposterdev

    local out
    out="$(provision_as imposterdev imposteruser)"
    assert_equals 1 "$?" "${out}"
    assert_matches "signed by CN=testdev, not cfg-provision" "${out}"
    assert_fails "test -e /home/imposteruser/.ssh/authorized_keys"
}

test_a_file_sealed_for_another_device_does_not_open() {
    install_fetch_provision
    device_esp swapdev

    local out
    out="$(provision_as swapdev swapuser)"
    assert_equals 1 "$?" "${out}"
    assert_matches "does not decrypt with this device's key" "${out}"
    assert_fails "test -e /home/swapuser/.ssh/authorized_keys"
}

test_a_sealed_file_without_a_ca_on_the_esp_is_opened_with_a_warning() {
    install_fetch_provision
    device_esp timedev noca

    local out
    out="$(provision_as timedev sealednoca)"
    assert_equals 0 "$?" "${out}"
    assert_matches "not verifying who signed" "${out}"
    assert "grep -qxF '${DEVICE_KEY}' /home/sealednoca/.ssh/authorized_keys"
}

install_k8s_roles() {
    local root
    root="${W}/k8s-root"
    mkdir -p "${root}/usr/bin"
    touch "${root}/usr/bin/kubeadm"
    chmod 0755 "${root}/usr/bin/kubeadm"
    (
        # shellcheck disable=SC1090
        source <(sed '/^args=("\$@")$/,$d' "${SCRIPT_UNDER_TEST}")
        log_level=quiet
        cfg_services="${CFG_SERVICES}"
        write_k8s_roles "${root}"
    )
    cp -a "${root}/etc/systemd/system/." /etc/systemd/system/
}

test_a_k8s_master_gets_the_cluster_and_its_pki() {
    install_fetch_provision
    install_k8s_roles
    device_esp k8smaster
    stub systemctl "echo \"\$*\" >>${W}/k8smaster-systemctl"

    local out
    out="$(provision_as k8smaster k8smasteruser)"
    assert_equals 0 "$?" "${out}"
    assert_equals "root:root 600" "$(stat -c '%U:%G %a' /etc/provision/k8s.conf)"
    assert "grep -qx K8S_ROLE=master /etc/provision/k8s.conf"
    assert "grep -qx K8S_BOOTSTRAP=yes /etc/provision/k8s.conf"
    assert "grep -qx 'K8S_CA_CERT_HASH=${K8S_HASH}' /etc/provision/k8s.conf"
    assert_equals "700" "$(stat -c '%a' /etc/provision/k8s-pki)"
    local f
    for f in ca.crt ca.key front-proxy-ca.crt front-proxy-ca.key etcd/ca.crt etcd/ca.key sa.key sa.pub; do
        assert_equals "root:root 600" "$(stat -c '%U:%G %a' "/etc/provision/k8s-pki/${f}")" "${f}"
    done
    assert "openssl pkey -in /etc/provision/k8s-pki/ca.key -noout" "the CA key arrives intact"
    assert "cmp -s ${W}/other-ca.pem /etc/provision/k8s-pki/ca.crt"
    assert "grep -qx 'enable role-k8s-master.target' ${W}/k8smaster-systemctl"
}

test_a_k8s_client_gets_the_cluster_without_pki() {
    install_fetch_provision
    install_k8s_roles
    rm -rf /etc/provision/k8s-pki
    device_esp k8sclient
    stub systemctl "echo \"\$*\" >>${W}/k8sclient-systemctl"

    local out
    out="$(provision_as k8sclient k8sclientuser)"
    assert_equals 0 "$?" "${out}"
    assert "grep -qx K8S_ROLE=client /etc/provision/k8s.conf"
    assert "grep -qx K8S_ENDPOINT=test.k8s.internal:6443 /etc/provision/k8s.conf"
    assert_fails "test -e /etc/provision/k8s-pki" "no cluster CA key on a client"
    assert "grep -qx 'enable role-k8s-client.target' ${W}/k8sclient-systemctl"
}

test_systemd_units_are_installed_enabled_and_started() {
    install_fetch_provision
    device_esp unitdev
    rm -rf "${W}/unitdev-bin"
    mkdir -p "${W}/unitdev-bin"
    : >"${W}/unitdev-systemctl"
    chmod 0711 "${W}"
    chmod 0755 "${W}/unitdev-bin"
    chmod 0666 "${W}/unitdev-systemctl"
    # shellcheck disable=SC2016
    printf '#!/bin/sh\nif [ "$(id -u)" = 0 ]; then echo "root $*"; else echo "$(id -un) HOME=${HOME} $*"; fi >>%s\n' \
        "${W}/unitdev-systemctl" >"${W}/unitdev-bin/systemctl"
    chmod 0755 "${W}/unitdev-bin/systemctl"

    local out
    id unituser >/dev/null 2>&1 || useradd -m -U unituser
    out="$(PATH="${W}/unitdev-bin:${W}/bin:${PATH}" PROVISION_ESP="${W}/unitdev-esp" "${FETCH[@]}" unituser 2>&1)"
    assert_equals 0 "$?" "${out}"
    chmod 0700 "${W}"
    assert "grep -qx 'ExecStart=/bin/true' /etc/systemd/system/provision-hello.service"
    assert "grep -qx 'Environment=PROVISIONED=1' /etc/systemd/system/ssh.service.d/10-provision.conf"
    assert "grep -qx 'WantedBy=default.target' /etc/systemd/user/provision-hello.service"
    assert_equals "root:root 644" "$(stat -c '%U:%G %a' /etc/systemd/system/provision-hello.service)"
    assert_equals "$(printf '%s\n' 'unituser HOME=/home/unituser --user --root=/ enable mine.service' \
        'root daemon-reload' 'root enable provision-hello.service' \
        'root --global enable provision-hello.service' 'root --no-block start provision-hello.service')" \
        "$(cat "${W}/unitdev-systemctl")" "the user's own units are enabled as that user"

    local u
    u=/home/unituser/.config/systemd/user
    assert "grep -qx 'ExecStart=/bin/true' ${u}/mine.service"
    assert "grep -qx 'Environment=MINE=1' ${u}/mine.service.d/10-env.conf"
    local f
    for f in /home/unituser/.config /home/unituser/.config/systemd "${u}" "${u}/mine.service.d" \
        "${u}/mine.service" "${u}/mine.service.d/10-env.conf"; do
        assert_equals unituser:unituser "$(stat -c %U:%G "${f}")" "${f}"
    done
    assert_fails "test -e /etc/systemd/user/mine.service" "for that user only"
}
