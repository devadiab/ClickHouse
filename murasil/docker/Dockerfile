# The Murasil ClickHouse server image: upstream's Ubuntu image recipe
# (docker/server/Dockerfile.ubuntu at the base tag), fed the binary this fork built
# instead of a package download, plus Murasil's config.d.
#
#   murasil/docker/build.sh            after murasil/build/builder-droplet.sh
#
# Build context is the repository root.
FROM ubuntu:22.04

ARG DEBIAN_FRONTEND=noninteractive
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8 TZ=UTC

RUN apt-get update \
    && apt-get install --yes --no-install-recommends ca-certificates locales tzdata wget \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /var/cache/debconf /tmp/* \
    && locale-gen en_US.UTF-8

# The single static binary carries server, client, keeper and the tools;
# `clickhouse install` lays out /etc, /var/lib and the symlinks the way the
# packages do, so upstream's entrypoint works unchanged.
COPY murasil/out/clickhouse /tmp/clickhouse
RUN groupadd -r clickhouse --gid=101 \
    && useradd -r -g clickhouse --uid=101 --home-dir=/var/lib/clickhouse --shell=/bin/bash clickhouse \
    && chmod +x /tmp/clickhouse \
    && /tmp/clickhouse install --user clickhouse --group clickhouse \
    && rm /tmp/clickhouse \
    && clickhouse-server --version \
    && mkdir -p /var/lib/clickhouse /var/log/clickhouse-server /etc/clickhouse-server /etc/clickhouse-client \
    && chmod ugo+Xrw -R /var/lib/clickhouse /var/log/clickhouse-server /etc/clickhouse-server /etc/clickhouse-client

RUN mkdir /docker-entrypoint-initdb.d
COPY docker/server/docker_related_config.xml /etc/clickhouse-server/config.d/
COPY murasil/config.d/*.xml /etc/clickhouse-server/config.d/
COPY murasil/users.d/*.xml /etc/clickhouse-server/users.d/
COPY docker/server/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 9000 8123 9009
VOLUME /var/lib/clickhouse
ENV CLICKHOUSE_CONFIG=/etc/clickhouse-server/config.xml

ENTRYPOINT ["/entrypoint.sh"]
