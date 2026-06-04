#!/bin/sh

set -eu

db_name="${POSTGRES_DB:-medusa-store}"
db_user="${POSTGRES_USER:-postgres}"

psql -v ON_ERROR_STOP=1 -U "$db_user" -d postgres -v db="$db_name" <<'SQL'
SELECT format('CREATE DATABASE %I', :'db')
WHERE NOT EXISTS (
  SELECT FROM pg_database WHERE datname = :'db'
)\gexec
SQL
