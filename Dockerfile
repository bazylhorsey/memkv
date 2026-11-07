# syntax=docker/dockerfile:1.7
#   docker build -t memkv:19rc1 .
#   docker run -d --name memkv --shm-size=256m -e POSTGRES_PASSWORD=postgres \
#              -p 5432:5432 memkv:19rc1
#   psql -h localhost -U postgres -c "CREATE EXTENSION memkv" \
#        -c "SELECT memkv.set('hello', 'world'), memkv.get('hello')"
#
# memkv needs PostgreSQL 19. Until it is released, the base is the official
# release-candidate image; change PG_TAG to 19 when that exists.
ARG PG_TAG=19rc1
ARG PG_MAJOR=19

FROM postgres:${PG_TAG} AS build
ARG PG_MAJOR
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential postgresql-server-dev-${PG_MAJOR} \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY Makefile memkv.control memkv.c memkv--*.sql ./
RUN make PG_CONFIG=/usr/lib/postgresql/${PG_MAJOR}/bin/pg_config \
 && make PG_CONFIG=/usr/lib/postgresql/${PG_MAJOR}/bin/pg_config install DESTDIR=/out

FROM postgres:${PG_TAG}
LABEL org.opencontainers.image.source="https://github.com/bazylhorsey/pg_kv" \
      org.opencontainers.image.description="PostgreSQL 19 with memkv: a Valkey-style key-value store in shared memory, no preload needed" \
      org.opencontainers.image.licenses="PostgreSQL"
COPY --from=build /out/ /
# memkv keeps its data in dynamic shared memory, which lives in /dev/shm.
# Docker gives a container 64 MB of it by default, so run with --shm-size
# larger than memkv.max_memory (64MB unless you change it).
