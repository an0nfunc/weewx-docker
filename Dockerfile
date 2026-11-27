FROM alpine:3.24@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf AS wheels

# CT3 is built here because PyPI has no musl wheels for it, and Alpine's
# py3-cheetah 3.3.3 predates the fix that stops its C extension printing
# ignored TypeErrors on every template lookup under Python 3.13+.
RUN apk add --no-cache build-base python3-dev py3-setuptools
RUN --mount=type=bind,source=requirements.txt,target=/tmp/requirements.txt \
    python3 -m venv --system-site-packages /build \
    && /build/bin/pip wheel --no-cache-dir --no-deps --no-build-isolation --require-hashes \
        -r /tmp/requirements.txt -w /wheels

FROM alpine:3.24@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf

# Alpine packages the remaining modules weewx imports, so this stage needs no
# compiler. apk upgrade pulls in fixes for packages the base image already ships.
RUN apk upgrade --no-cache \
    && apk add --no-cache \
        openssh-client \
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

# /data/lib/python comes last on the path, so packages installed there cannot
# shadow the image's own. Root processes leave it off the path, so nothing the
# container user writes there runs as root. The empty sitecustomize keeps one
# planted under /data from running in every Python process.
RUN --mount=type=bind,from=wheels,source=/wheels,target=/tmp/wheels \
    python3 -m venv --system-site-packages /opt/weewx \
    && /opt/weewx/bin/pip install --no-cache-dir --no-index --no-deps /tmp/wheels/*.whl \
    && /opt/weewx/bin/pip check \
    && purelib=$(python3 -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])') \
    && echo "import os, sys; os.geteuid() and sys.path.append('/data/lib/python')" > "$purelib/zz-weewx-data.pth" \
    && touch "$purelib/sitecustomize.py"

# The default station is created here rather than on first start because
# weectl looks up the user and group names, which a --user uid may not have.
# It is created in /data so its paths are right, then moved aside for the
# entrypoint to copy into /data.
RUN --mount=type=bind,source=station-defaults.py,target=/tmp/station-defaults.py \
    su -s /bin/sh weewx -c '/opt/weewx/bin/weectl station create /data --no-prompt' \
    && su -s /bin/sh weewx -c '/opt/weewx/bin/python3 /tmp/station-defaults.py /data/weewx.conf' \
    && mkdir /opt/weewx/station \
    && find /data -mindepth 1 -maxdepth 1 -exec mv {} /opt/weewx/station/ \; \
    && chown -R root:root /opt/weewx/station

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

# HOME is set explicitly so weectl finds ~/weewx-data under any --user uid.
ENV PATH=/opt/weewx/bin:$PATH \
    HOME=/home/weewx \
    PYTHONNOUSERSITE=1 \
    PYTHONSAFEPATH=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

USER weewx
WORKDIR /data
VOLUME /data

# weewxd stops by signalling its own process group, which PID 1 would ignore.
ENTRYPOINT ["/sbin/tini", "--", "docker-entrypoint.sh"]
CMD ["weewxd", "/data/weewx.conf"]
