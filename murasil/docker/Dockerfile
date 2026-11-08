# The Murasil ClickHouse server image: upstream's Ubuntu image recipe
# (docker/server/Dockerfile.ubuntu at the base tag), fed the binary this fork built
# instead of a package download, plus Murasil's config.d.
#
#   murasil/docker/build.sh            after murasil/build/builder-droplet.sh
#
# Build context is murasil/out/context, which build.sh stages: the binary, upstream's
# entrypoint and docker config, and Murasil's config.d / users.d. The repository
# itself (1.6 GB of sources) never enters the context.
FROM ubuntu:22.04

ARG DEBIAN_FRONTEND=noninteractive
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8 TZ=UTC
# jemalloc keeps freed pages for a minute instead of five seconds before returning them to
# the kernel: under the platform's writes (7000 msg/s x 300 s, two cycles) inserts cost 59 s
# of CPU against 62 and 61 with the stock decay, the rest of the string is the stock value.
# The memory worker still purges when memory runs short.
ENV MALLOC_CONF=percpu_arena:percpu,oversize_threshold:0,muzzy_decay_ms:0,dirty_decay_ms:60000

RUN apt-get update \
    && apt-get install --yes --no-install-recommends ca-certificates locales tzdata wget \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /var/cache/debconf /tmp/* \
    && locale-gen en_US.UTF-8

# The single static binary carries server, client, keeper and the tools;
# `clickhouse install` lays out /etc, /var/lib and the symlinks the way the
# packages do, so upstream's entrypoint works unchanged.
COPY clickhouse /tmp/clickhouse
RUN groupadd -r clickhouse --gid=101 \
    && useradd -r -g clickhouse --uid=101 --home-dir=/var/lib/clickhouse --shell=/bin/bash clickhouse \
    && chmod +x /tmp/clickhouse \
    && /tmp/clickhouse install --user clickhouse --group clickhouse \
    && rm /tmp/clickhouse \
    && clickhouse-server --version \
    && mkdir -p /var/lib/clickhouse /var/log/clickhouse-server /etc/clickhouse-server /etc/clickhouse-client \
    && chmod ugo+Xrw -R /var/lib/clickhouse /var/log/clickhouse-server /etc/clickhouse-server /etc/clickhouse-client

RUN mkdir /docker-entrypoint-initdb.d
COPY docker_related_config.xml /etc/clickhouse-server/config.d/
COPY config.d/*.xml /etc/clickhouse-server/config.d/
COPY users.d/*.xml /etc/clickhouse-server/users.d/
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 9000 8123 9009
VOLUME /var/lib/clickhouse
ENV CLICKHOUSE_CONFIG=/etc/clickhouse-server/config.xml

ENTRYPOINT ["/entrypoint.sh"]
