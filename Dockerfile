# syntax=docker/dockerfile:1
FROM alpine:3.24@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf

# Alpine packages every module weewx imports, so the image needs no compiler and
# weewx itself installs without dependencies.
RUN apk add --no-cache \
        openssh-client \
        py3-cheetah \
        py3-configobj \
        py3-ephem \
        py3-paho-mqtt \
        py3-pillow \
        py3-pymysql \
        py3-pyserial \
        py3-usb \
        python3 \
        rsync \
        rtl_433 \
        tini \
        tzdata \
    && addgroup -g 1000 weewx \
    && adduser -D -u 1000 -G weewx -h /home/weewx -s /sbin/nologin weewx \
    && install -d -o weewx -g weewx /data \
    && ln -s /data /home/weewx/weewx-data

RUN --mount=type=bind,source=requirements.txt,target=/tmp/requirements.txt \
    python3 -m venv --system-site-packages /opt/weewx \
    && /opt/weewx/bin/pip install --no-cache-dir --no-deps --require-hashes \
        -r /tmp/requirements.txt \
    && /opt/weewx/bin/pip check

# The default station is created here rather than on first start because
# weectl looks up the user and group names, which a --user uid may not have.
# It is created in /data so its paths are right, then moved aside for the
# entrypoint to copy back into an empty volume.
RUN --mount=type=bind,source=station-defaults.py,target=/tmp/station-defaults.py \
    su -s /bin/sh weewx -c '/opt/weewx/bin/weectl station create /data --no-prompt' \
    && su -s /bin/sh weewx -c '/opt/weewx/bin/python3 /tmp/station-defaults.py /data/weewx.conf' \
    && mkdir /opt/weewx/station \
    && find /data -mindepth 1 -maxdepth 1 -exec mv {} /opt/weewx/station/ \;

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

# HOME is set explicitly so weectl finds ~/weewx-data under any --user uid.
ENV PATH=/opt/weewx/bin:$PATH \
    HOME=/home/weewx \
    PYTHONPATH=/data/lib/python \
    PIP_DISABLE_PIP_VERSION_CHECK=1

USER weewx
WORKDIR /data
VOLUME /data

# weewxd stops by signalling its own process group, which PID 1 would ignore.
ENTRYPOINT ["/sbin/tini", "--", "docker-entrypoint.sh"]
CMD ["weewxd", "/data/weewx.conf"]
