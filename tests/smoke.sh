#!/bin/sh
# Usage: tests/smoke.sh IMAGE
set -eu

image=$1
expected=$(sed -n 's/^weewx==\([^ ]*\).*/\1/p' "$(dirname "$0")/../requirements.txt")
prefix=weewx-smoke-$$
bind=$(mktemp -d)

cleanup() {
    docker rm -f "$prefix" "$prefix-uid" "$prefix-ro" >/dev/null 2>&1 || true
    docker volume rm "$prefix" "$prefix-ro" >/dev/null 2>&1 || true
    # The station in $bind belongs to uid 4242, so remove it from inside a container.
    docker run --rm --user 0 -v "$bind:/mnt" "$image" find /mnt -mindepth 1 -delete >/dev/null 2>&1 || true
    rmdir "$bind" 2>/dev/null || true
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# wait_for CONTAINER PATTERN [COUNT]: until PATTERN appears COUNT times in the logs.
wait_for() {
    i=0
    until [ "$(docker logs "$1" 2>&1 | grep -c "$2")" -ge "${3:-1}" ]; do
        i=$((i + 1))
        if [ "$i" -ge 60 ]; then
            docker logs "$1" >&2
            fail "$1: timed out waiting for '$2'"
        fi
        sleep 1
    done
}

echo "* bundled modules and weewx version"
version=$(docker run --rm "$image" python3 -c '
import Cheetah, configobj, ephem, paho.mqtt.client, PIL, pymysql, serial, sqlite3, usb
import weewx
print(weewx.__version__)')
[ "$version" = "$expected" ] || fail "weewx is $version, requirements.txt pins $expected"
docker run --rm "$image" rtl_433 -V 2>&1 | grep -q 'rtl_433 version' || fail "rtl_433 does not run"

echo "* first start creates a station"
docker run -d --name "$prefix" -v "$prefix:/data" "$image" >/dev/null
wait_for "$prefix" 'Starting main packet loop'
# The Simulator emits a LOOP packet every 2.5 s; give StdPrint a chance to show up.
sleep 6
logs=$(docker logs "$prefix" 2>&1)
case $logs in *'Logging error'*) fail "logging errors in the output" ;; esac
case $logs in *'LOOP:'*) fail "StdPrint still prints LOOP packets" ;; esac
docker exec "$prefix" weectl extension list >/dev/null || fail "weectl does not find the station"

echo "* docker stop ends weewxd promptly"
start=$(date +%s)
docker stop "$prefix" >/dev/null
[ $(($(date +%s) - start)) -lt 8 ] || fail "docker stop needed more than 8 s"

echo "* second start reuses the station"
docker start "$prefix" >/dev/null
wait_for "$prefix" 'Starting main packet loop' 2
[ "$(docker logs "$prefix" 2>&1 | grep -c 'creating a new station')" -eq 1 ] ||
    fail "station was created twice"

echo "* a non-default uid owning a bind-mounted /data works"
docker run --rm --user 0 -v "$bind:/mnt" "$image" chown 4242:4242 /mnt
docker run -d --name "$prefix-uid" --user 4242:4242 -v "$bind:/data" "$image" >/dev/null
wait_for "$prefix-uid" 'Starting main packet loop'
docker exec "$prefix-uid" weectl extension list >/dev/null || fail "weectl fails under uid 4242"

echo "* an unwritable /data fails with a message"
if docker run --name "$prefix-ro" --user 4243:4243 -v "$prefix-ro:/data" "$image" >/dev/null 2>&1; then
    fail "container started without a writable /data"
fi
docker logs "$prefix-ro" 2>&1 | grep -q 'is not writable by uid 4243' || fail "no message about /data"

echo "all smoke tests passed"
