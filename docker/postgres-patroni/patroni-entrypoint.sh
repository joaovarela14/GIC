#!/bin/sh

set -eu

: "${POD_NAME:?POD_NAME is required}"
: "${POD_NAMESPACE:?POD_NAMESPACE is required}"
: "${POD_IP:?POD_IP is required}"
: "${POSTGRES_DB:?POSTGRES_DB is required}"
: "${POSTGRES_USER:?POSTGRES_USER is required}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}"
: "${POSTGRES_REPLICATION_PASSWORD:?POSTGRES_REPLICATION_PASSWORD is required}"

export PGDATA="${PGDATA:-/var/lib/postgresql/data/pgdata}"

if [ "$(id -u)" = "0" ]; then
  mkdir -p "$PGDATA"
  chown -R postgres:postgres /var/lib/postgresql/data
  exec gosu postgres "$0" "$@"
fi

envsubst < /etc/patroni/patroni.yml.tpl > /tmp/patroni.yml

exec patroni /tmp/patroni.yml
