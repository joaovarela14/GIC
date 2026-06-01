FROM postgres:15-bookworm

ARG PATRONI_VERSION=4.0.6
ARG KUBERNETES_CLIENT_VERSION=36.0.1

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      gettext-base \
      gcc \
      libpq-dev \
      python3-dev \
      python3-venv; \
    python3 -m venv /opt/patroni; \
    /opt/patroni/bin/pip install --no-cache-dir --upgrade pip setuptools wheel; \
    /opt/patroni/bin/pip install --no-cache-dir \
      "patroni[kubernetes,psycopg3]==${PATRONI_VERSION}" \
      "kubernetes==${KUBERNETES_CLIENT_VERSION}"; \
    ln -s /opt/patroni/bin/patroni /usr/local/bin/patroni; \
    ln -s /opt/patroni/bin/patronictl /usr/local/bin/patronictl; \
    apt-get purge -y --auto-remove gcc python3-dev libpq-dev; \
    rm -rf /var/lib/apt/lists/*

COPY patroni-entrypoint.sh /usr/local/bin/patroni-entrypoint.sh
COPY patroni-post-init.sh /usr/local/bin/patroni-post-init.sh

RUN chmod +x /usr/local/bin/patroni-entrypoint.sh /usr/local/bin/patroni-post-init.sh

ENTRYPOINT ["/usr/local/bin/patroni-entrypoint.sh"]
