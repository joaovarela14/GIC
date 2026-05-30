# Redis Sentinel — Verification & HA Guide

How to verify the Redis Sentinel high-availability setup added in the `sentinel`
commit is working as intended.

## What was deployed

The single-replica Redis `Deployment` was replaced by a 3-replica `StatefulSet`
(`k8s/tenant/redis.yaml`). Each pod runs two containers:

- `redis` (port `6379`) — self-configures as master or replica at startup via
  `redis-start.sh`.
- `sentinel` (port `26379`) — monitors the master via `sentinel-start.sh`.

Services:

| Service          | Type           | Purpose                                            |
| ---------------- | -------------- | -------------------------------------------------- |
| `redis-headless` | Headless       | Stable per-pod DNS (`redis-0.redis-headless`, ...) |
| `redis-sentinel` | ClusterIP      | Sentinel endpoint clients query (`:26379`)         |
| `redis`          | ClusterIP      | Legacy direct master/replica access (`:6379`)      |

Master name: `pisofire-redis`. Quorum: `2`. `down-after` 5s, `failover-timeout` 30s.

Medusa connects **through Sentinel** (ioredis `{ sentinels, name, role: "master" }`),
configured in `my-medusa-store/medusa-config.ts` and fed by `REDIS_SENTINEL_NAME` /
`REDIS_SENTINEL_HOSTS` from the ConfigMap.

```bash
export NS=tenant-pisofire     # kustomize deploys into this namespace
export MASTER_NAME=pisofire-redis
```

## 1. Workloads are healthy

```bash
kubectl get statefulset redis -n $NS                 # READY 3/3
kubectl get pods -n $NS -l app=redis -o wide         # each pod 2/2 Running
kubectl get pvc -n $NS | grep redis-data-redis        # one PVC per ordinal, Bound
kubectl get endpoints redis-headless redis-sentinel -n $NS
```

Expected: 3 pods `2/2`, three bound PVCs (`redis-data-redis-0/1/2`), and the
`redis-sentinel` endpoint listing 3 addresses on `:26379`.

## 2. Replication topology — exactly one master

```bash
for i in 0 1 2; do printf 'redis-%s: ' "$i"; \
  kubectl exec -n $NS redis-$i -c redis -- redis-cli role | head -1; done
```

Expected: exactly **one** `master`, two `slave`. Then confirm from the master's view:

```bash
# find current master pod
MASTER=$(kubectl exec -n $NS redis-0 -c sentinel -- \
  redis-cli -p 26379 SENTINEL get-master-addr-by-name $MASTER_NAME | sed -n 1p | tr -d '\r')
MASTER_POD=${MASTER%%.*}
echo "master = $MASTER_POD"
kubectl exec -n $NS "$MASTER_POD" -c redis -- redis-cli info replication
```

Expected: `role:master` with `connected_slaves:2`, both `state=online` and low `lag`.

## 3. Sentinel quorum & monitoring

```bash
kubectl exec -n $NS redis-0 -c sentinel -- redis-cli -p 26379 SENTINEL ckquorum $MASTER_NAME
kubectl exec -n $NS redis-0 -c sentinel -- redis-cli -p 26379 SENTINEL master $MASTER_NAME \
  | paste - - | grep -E 'flags|num-slaves|num-other-sentinels|quorum'
```

Expected:

- `ckquorum` → `OK 3 usable Sentinels. Quorum and failover authorization can be reached`
- `flags master` (not `s_down`/`o_down`), `num-other-sentinels 2`, `quorum 2`.

> Note: `num-slaves` should be `2`. If it reads `3` (while the master shows
> `connected_slaves:2`), Sentinel is holding a stale replica entry — see Troubleshooting.

## 4. Replication actually works

```bash
kubectl exec -n $NS "$MASTER_POD" -c redis -- redis-cli set ha:probe "$(date +%s)"
# read it back from a replica (replicas are read-only)
for i in 0 1 2; do [ "redis-$i" = "$MASTER_POD" ] && continue; \
  printf 'redis-%s: ' "$i"; kubectl exec -n $NS redis-$i -c redis -- redis-cli get ha:probe; done
kubectl exec -n $NS "$MASTER_POD" -c redis -- redis-cli del ha:probe
```

Expected: both replicas return the value written on the master.

## 5. Client (Medusa) is Sentinel-aware

```bash
POD=$(kubectl get pod -n $NS -l app=medusa -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n $NS "$POD" -- sh -c 'env | grep -E "REDIS_SENTINEL_(NAME|HOSTS)|REDIS_URL"'
```

Expected: `REDIS_SENTINEL_NAME=pisofire-redis` and `REDIS_SENTINEL_HOSTS` listing the
three `redis-N.redis-headless:26379` endpoints. Also confirm the app reports ready:

```bash
kubectl exec -n $NS "$POD" -- wget -qO- http://localhost:9000/readyz && echo OK
```

## 6. HA failover test

This proves the cluster survives losing the master. Run during a maintenance window —
it triggers a real promotion.

### 6a. Graceful (Sentinel-initiated)

```bash
MASTER=$(kubectl exec -n $NS redis-0 -c sentinel -- \
  redis-cli -p 26379 SENTINEL get-master-addr-by-name $MASTER_NAME | sed -n 1p | tr -d '\r')
MASTER_POD=${MASTER%%.*}; PROBE=redis-0; [ "$MASTER_POD" = redis-0 ] && PROBE=redis-1
echo "old master = $MASTER_POD"

kubectl exec -n $NS "$PROBE" -c sentinel -- redis-cli -p 26379 SENTINEL failover $MASTER_NAME

# watch the master address change (within ~30s)
for n in $(seq 1 12); do
  kubectl exec -n $NS "$PROBE" -c sentinel -- \
    redis-cli -p 26379 SENTINEL get-master-addr-by-name $MASTER_NAME | sed -n 1p | tr -d '\r'
  sleep 3
done
```

Expected: the reported master switches to a different pod, and `ckquorum` still returns OK.

### 6b. Hard failure (kill the master pod)

```bash
# recompute current master first
MASTER=$(kubectl exec -n $NS redis-0 -c sentinel -- \
  redis-cli -p 26379 SENTINEL get-master-addr-by-name $MASTER_NAME | sed -n 1p | tr -d '\r')
MASTER_POD=${MASTER%%.*}; PROBE=redis-0; [ "$MASTER_POD" = redis-0 ] && PROBE=redis-1
echo "killing master $MASTER_POD"

kubectl delete pod "$MASTER_POD" -n $NS
```

Within ~5s (`down-after-milliseconds`) Sentinel marks it down and promotes a replica.
Verify:

```bash
# 1. a new master was elected (different pod)
kubectl exec -n $NS "$PROBE" -c sentinel -- \
  redis-cli -p 26379 SENTINEL get-master-addr-by-name $MASTER_NAME
# 2. still exactly one master across the cluster
for i in 0 1 2; do printf 'redis-%s: ' "$i"; \
  kubectl exec -n $NS redis-$i -c redis -- redis-cli role 2>/dev/null | head -1; done
# 3. Medusa stays ready throughout
kubectl exec -n $NS "$POD" -- wget -qO- http://localhost:9000/readyz && echo OK
```

Expected:

- A new master is serving within seconds.
- Once the StatefulSet recreates the killed pod, it rejoins as a **replica** of the new
  master (`redis-start.sh` discovers the master via Sentinel on boot).
- Medusa keeps responding (ioredis re-resolves the master from Sentinel).

Re-run section 2 afterward to confirm the topology settled to one master + two replicas.

### 6c. End-to-end app check (optional)

Run the tenant smoke test, which now asserts one Redis master + replicas and a valid
Sentinel master, and exercises an order through Medusa:

```bash
./scripts/smoke-test-tenant-k8s.sh
```

## Troubleshooting

**`num-slaves` higher than `connected_slaves` / stale replica entries.**
Sentinel tracks replicas by announced address. If the announce address changed (e.g. the
script was updated from short name `redis-0.redis-headless` to the FQDN
`redis-0.redis-headless.$NS.svc.cluster.local`), Sentinel keeps both as separate entries.
It's cosmetic and does not block failover, but to clean it up force each Sentinel to
re-discover replicas and sentinels:

```bash
for i in 0 1 2; do kubectl exec -n $NS redis-$i -c sentinel -- \
  redis-cli -p 26379 SENTINEL reset $MASTER_NAME; done
# verify it settles back to num-slaves 2
kubectl exec -n $NS redis-0 -c sentinel -- redis-cli -p 26379 SENTINEL master $MASTER_NAME \
  | paste - - | grep num-slaves
```

**Two masters / split brain after a full restart.** If every pod restarts at once and no
Sentinel is reachable, `redis-start.sh` falls back to `redis-0` as master. Once Sentinels
are up they reconcile to a single master. Confirm with section 2.

**Inspect persisted state.**

```bash
kubectl exec -n $NS redis-0 -c sentinel -- cat /data/sentinel.conf
kubectl exec -n $NS redis-0 -c redis     -- cat /data/redis.conf
kubectl logs -n $NS redis-0 -c sentinel --tail=50
```
