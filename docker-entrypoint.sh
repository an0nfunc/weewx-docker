#!/bin/sh
set -eu

data=/data
config=$data/weewx.conf

if [ "${1:-}" = weewxd ]; then
    if [ ! -e "$config" ]; then
        if [ ! -w "$data" ]; then
            echo "error: $data is not writable by uid $(id -u), so no station can be created there." >&2
            echo "Make it writable by that uid, or run the container as the owner of $data." >&2
            exit 1
        fi
        echo "No $config found, creating a new station that uses the Simulator driver."
        # Only fill in what is missing, so existing skins and extensions survive.
        for entry in /opt/weewx/station/*; do
            [ -e "$data/${entry##*/}" ] || cp -R "$entry" "$data/"
        done
        # Credentials go into this file.
        chmod 600 "$config"
        echo "Edit $config for your station, then restart the container."
    elif ! grep -q '^\[Logging\]' "$config"; then
        echo "warning: $config has no [Logging] section, so weewxd logs to syslog," >&2
        echo "which does not exist in this container. See the README to log to the container output." >&2
    fi
fi

exec "$@"
