#!/bin/sh
# Usage: tests/smoke.sh IMAGE
set -eu

image=$1
expected=$(sed -n 's/^weewx==\([^ ]*\).*/\1/p' "$(dirname "$0")/../requirements.txt")
prefix=weewx-smoke-$$
bind=$(mktemp -d)

cleanup() {
    docker rm -f "$prefix" "$prefix-uid" "$prefix-ro" "$prefix-keep" >/dev/null 2>&1 || true
    docker volume rm "$prefix" "$prefix-ro" "$prefix-keep" "$prefix-py" >/dev/null 2>&1 || true
    # The station in $bind belongs to uid 4242, so empty it and hand it back from a container.
    docker run --rm --user 0 -v "$bind:/mnt" "$image" \
        sh -c 'find /mnt -mindepth 1 -delete && chown "$0" /mnt' "$(id -u):$(id -g)" >/dev/null 2>&1 || true
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
[ "$(docker run --rm "$image" stat -c %U /opt/weewx/station/weewx.conf)" = root ] ||
    fail "the station template is writable by the container user"

echo "* /data/lib/python adds packages but cannot shadow or inject code"
out=$(docker run --rm -i -v "$prefix-py:/data" "$image" sh -s 2>&1 <<'EOF'
usersite=$(python3 -c 'import site; print(site.getusersitepackages())')
mkdir -p /data/lib/python/configobj "$usersite"
echo 'MARKER = 1' > /data/lib/python/smoke_marker.py
echo 'raise SystemExit("shadowed")' > /data/lib/python/configobj/__init__.py
echo 'print("PLANTED")' > /data/lib/python/sitecustomize.py
echo 'import sys; print("PLANTED")' > "$usersite/planted.pth"
echo 'print("PLANTED")' > /data/configobj.py
cd /data && python3 -c 'import configobj, smoke_marker; print("ok")'
EOF
)
[ "$out" = ok ] || fail "python path: $out"

echo "* first start creates a station"
docker run -d --name "$prefix" -v "$prefix:/data" "$image" >/dev/null
wait_for "$prefix" 'Starting main packet loop'
docker logs "$prefix" 2>&1 | grep -q 'Logging error' && fail "logging errors in the output"
docker exec "$prefix" grep -q '^ *report_services = .*StdPrint' /data/weewx.conf &&
    fail "StdPrint is still configured"
[ "$(docker exec "$prefix" stat -c %a /data/weewx.conf)" = 600 ] || fail "weewx.conf is not mode 600"
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

echo "* a new station keeps files already in /data"
docker run --rm --user 0 -v "$prefix-keep:/data" "$image" sh -c '
mkdir -p /data/bin/user && echo "# keep me" > /data/bin/user/extensions.py && chown -R 1000:1000 /data'
docker run -d --name "$prefix-keep" -v "$prefix-keep:/data" "$image" >/dev/null
wait_for "$prefix-keep" 'Starting main packet loop'
[ "$(docker exec "$prefix-keep" cat /data/bin/user/extensions.py)" = "# keep me" ] ||
    fail "existing extensions.py was overwritten"
docker exec "$prefix-keep" test -f /data/skins/Seasons/skin.conf || fail "missing skins were not added"

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
