#!/bin/sh

set -eu

NAMESPACE="${NAMESPACE:-pisofire}"
TARGET_DEPLOYMENT="${TARGET_DEPLOYMENT:-storefront}"
HPA_NAME="${HPA_NAME:-$TARGET_DEPLOYMENT}"
SERVICE_CHECK_IMAGE="${SERVICE_CHECK_IMAGE:-busybox:1.36}"
LOAD_WORKERS="${LOAD_WORKERS:-2}"
LOAD_DURATION_SECONDS="${LOAD_DURATION_SECONDS:-120}"
HPA_TIMEOUT_SECONDS="${HPA_TIMEOUT_SECONDS:-240}"
CONTROLLED_HPA_DEMO="${CONTROLLED_HPA_DEMO:-true}"
KUBECONFIG_FILE="${KUBECONFIG_FILE:-}"
EXPECTED_CONTEXT="${EXPECTED_CONTEXT:-}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

kubectl_cmd() {
  if [ -n "$KUBECONFIG_FILE" ]; then
    kubectl --kubeconfig "$KUBECONFIG_FILE" "$@"
  else
    kubectl "$@"
  fi
}

validate_context() {
  current_context="$(kubectl_cmd config current-context 2>/dev/null || true)"

  if [ -n "$EXPECTED_CONTEXT" ]; then
    if [ "$current_context" != "$EXPECTED_CONTEXT" ]; then
      echo "Refusing to run HPA test." >&2
      echo "Current context: $current_context" >&2
      echo "Expected context: $EXPECTED_CONTEXT" >&2
      exit 1
    fi
    return
  fi

  current_cluster="$(kubectl_cmd config view --minify -o jsonpath='{.contexts[0].context.cluster}' 2>/dev/null || true)"
  cluster_name="${CLUSTER_NAME:-}"

  if [ -z "$cluster_name" ]; then
    case "$current_cluster" in
      k3d-*) cluster_name="${current_cluster#k3d-}" ;;
      *) cluster_name="pisofire" ;;
    esac
  fi

  expected_cluster="k3d-$cluster_name"

  if [ "$current_cluster" != "$expected_cluster" ]; then
    echo "Refusing to run HPA test." >&2
    echo "Current context: $current_context" >&2
    echo "Current cluster: ${current_cluster:-<none>}" >&2
    echo "Expected cluster: $expected_cluster" >&2
    echo "For tenant, set KUBECONFIG_FILE and EXPECTED_CONTEXT explicitly." >&2
    exit 1
  fi
}

original_targets() {
  case "$HPA_NAME" in
    medusa|storefront)
      ORIGINAL_MIN_REPLICAS=2
      ORIGINAL_MAX_REPLICAS=5
      ORIGINAL_CPU_TARGET=70
      ORIGINAL_MEMORY_TARGET=80
      ;;
    medusa-worker)
      ORIGINAL_MIN_REPLICAS=1
      ORIGINAL_MAX_REPLICAS=3
      ORIGINAL_CPU_TARGET=75
      ORIGINAL_MEMORY_TARGET=80
      ;;
    *)
      echo "Unsupported HPA for automatic restore: $HPA_NAME" >&2
      echo "Use medusa, storefront, or medusa-worker." >&2
      exit 1
      ;;
  esac
}

validate_target() {
  if [ "$HPA_NAME" != "$TARGET_DEPLOYMENT" ]; then
    echo "This script expects HPA_NAME to match TARGET_DEPLOYMENT." >&2
    echo "Current TARGET_DEPLOYMENT=$TARGET_DEPLOYMENT HPA_NAME=$HPA_NAME" >&2
    exit 1
  fi

  case "$TARGET_DEPLOYMENT" in
    medusa|storefront) ;;
    medusa-worker)
      echo "medusa-worker is configured with an HPA, but this demo only generates HTTP load for medusa or storefront." >&2
      exit 1
      ;;
    *)
      echo "Unsupported target deployment: $TARGET_DEPLOYMENT" >&2
      echo "Use medusa or storefront." >&2
      exit 1
      ;;
  esac
}

patch_hpa() {
  min_replicas="$1"
  max_replicas="$2"
  cpu_target="$3"
  memory_target="$4"

  kubectl_cmd patch hpa -n "$NAMESPACE" "$HPA_NAME" --type=merge -p "{
    \"spec\": {
      \"minReplicas\": $min_replicas,
      \"maxReplicas\": $max_replicas,
      \"metrics\": [
        {
          \"type\": \"Resource\",
          \"resource\": {
            \"name\": \"cpu\",
            \"target\": {
              \"type\": \"Utilization\",
              \"averageUtilization\": $cpu_target
            }
          }
        },
        {
          \"type\": \"Resource\",
          \"resource\": {
            \"name\": \"memory\",
            \"target\": {
              \"type\": \"Utilization\",
              \"averageUtilization\": $memory_target
            }
          }
        }
      ]
    }
  }" >/dev/null
}

patch_hpa_cleanup() {
  replicas="$1"

  kubectl_cmd patch hpa -n "$NAMESPACE" "$HPA_NAME" --type=merge -p "{
    \"spec\": {
      \"minReplicas\": $replicas,
      \"maxReplicas\": $replicas,
      \"metrics\": [
        {
          \"type\": \"Resource\",
          \"resource\": {
            \"name\": \"cpu\",
            \"target\": {
              \"type\": \"Utilization\",
              \"averageUtilization\": $ORIGINAL_CPU_TARGET
            }
          }
        },
        {
          \"type\": \"Resource\",
          \"resource\": {
            \"name\": \"memory\",
            \"target\": {
              \"type\": \"Utilization\",
              \"averageUtilization\": $ORIGINAL_MEMORY_TARGET
            }
          }
        }
      ],
      \"behavior\": {
        \"scaleUp\": {
          \"stabilizationWindowSeconds\": 0,
          \"selectPolicy\": \"Max\",
          \"policies\": [
            {
              \"type\": \"Pods\",
              \"value\": 1000,
              \"periodSeconds\": 15
            }
          ]
        },
        \"scaleDown\": {
          \"stabilizationWindowSeconds\": 0,
          \"selectPolicy\": \"Max\",
          \"policies\": [
            {
              \"type\": \"Pods\",
              \"value\": 1000,
              \"periodSeconds\": 15
            }
          ]
        }
      }
    }
  }" >/dev/null
}

restore_hpa_spec() {
  case "$HPA_NAME" in
    medusa|storefront)
      kubectl_cmd patch hpa -n "$NAMESPACE" "$HPA_NAME" --type=merge -p "{
        \"spec\": {
          \"minReplicas\": $ORIGINAL_MIN_REPLICAS,
          \"maxReplicas\": $ORIGINAL_MAX_REPLICAS,
          \"metrics\": [
            {
              \"type\": \"Resource\",
              \"resource\": {
                \"name\": \"cpu\",
                \"target\": {
                  \"type\": \"Utilization\",
                  \"averageUtilization\": $ORIGINAL_CPU_TARGET
                }
              }
            },
            {
              \"type\": \"Resource\",
              \"resource\": {
                \"name\": \"memory\",
                \"target\": {
                  \"type\": \"Utilization\",
                  \"averageUtilization\": $ORIGINAL_MEMORY_TARGET
                }
              }
            }
          ],
          \"behavior\": {
            \"scaleUp\": {
              \"stabilizationWindowSeconds\": 30,
              \"selectPolicy\": \"Max\",
              \"policies\": [
                {
                  \"type\": \"Percent\",
                  \"value\": 100,
                  \"periodSeconds\": 60
                },
                {
                  \"type\": \"Pods\",
                  \"value\": 2,
                  \"periodSeconds\": 60
                }
              ]
            },
            \"scaleDown\": {
              \"stabilizationWindowSeconds\": 300,
              \"policies\": [
                {
                  \"type\": \"Percent\",
                  \"value\": 50,
                  \"periodSeconds\": 60
                }
              ]
            }
          }
        }
      }" >/dev/null
      ;;
    medusa-worker)
      kubectl_cmd patch hpa -n "$NAMESPACE" "$HPA_NAME" --type=merge -p "{
        \"spec\": {
          \"minReplicas\": $ORIGINAL_MIN_REPLICAS,
          \"maxReplicas\": $ORIGINAL_MAX_REPLICAS,
          \"metrics\": [
            {
              \"type\": \"Resource\",
              \"resource\": {
                \"name\": \"cpu\",
                \"target\": {
                  \"type\": \"Utilization\",
                  \"averageUtilization\": $ORIGINAL_CPU_TARGET
                }
              }
            },
            {
              \"type\": \"Resource\",
              \"resource\": {
                \"name\": \"memory\",
                \"target\": {
                  \"type\": \"Utilization\",
                  \"averageUtilization\": $ORIGINAL_MEMORY_TARGET
                }
              }
            }
          ],
          \"behavior\": {
            \"scaleUp\": {
              \"stabilizationWindowSeconds\": 60,
              \"policies\": [
                {
                  \"type\": \"Pods\",
                  \"value\": 1,
                  \"periodSeconds\": 60
                }
              ]
            },
            \"scaleDown\": {
              \"stabilizationWindowSeconds\": 300,
              \"policies\": [
                {
                  \"type\": \"Pods\",
                  \"value\": 1,
                  \"periodSeconds\": 120
                }
              ]
            }
          }
        }
      }" >/dev/null
      ;;
  esac
}

restore_hpa() {
  if [ "${HPA_PATCHED:-false}" = "true" ]; then
    echo "Restoring HPA targets for $HPA_NAME"
    restore_hpa_spec || true
  fi
}

wait_for_replicas() {
  expected_replicas="$1"
  timeout_seconds="$2"
  deadline=$(( $(date +%s) + timeout_seconds ))

  while [ "$(date +%s)" -lt "$deadline" ]; do
    desired_replicas="$(kubectl_cmd get deployment -n "$NAMESPACE" "$TARGET_DEPLOYMENT" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
    ready_replicas="$(kubectl_cmd get deployment -n "$NAMESPACE" "$TARGET_DEPLOYMENT" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"

    desired_replicas="${desired_replicas:-0}"
    ready_replicas="${ready_replicas:-0}"

    if [ "$desired_replicas" -eq "$expected_replicas" ] && [ "$ready_replicas" -eq "$expected_replicas" ]; then
      return 0
    fi

    sleep 5
  done

  return 1
}

metric_is_below_target() {
  metric_value="$1"
  metric_target="$2"

  case "$metric_value" in
    ""|*[!0-9]*) return 0 ;;
  esac

  [ "$metric_value" -le "$metric_target" ]
}

wait_for_hpa_cooldown() {
  timeout_seconds="$1"
  deadline=$(( $(date +%s) + timeout_seconds ))

  while [ "$(date +%s)" -lt "$deadline" ]; do
    current_cpu="$(kubectl_cmd get hpa -n "$NAMESPACE" "$HPA_NAME" -o jsonpath='{.status.currentMetrics[?(@.resource.name=="cpu")].resource.current.averageUtilization}' 2>/dev/null || true)"
    current_memory="$(kubectl_cmd get hpa -n "$NAMESPACE" "$HPA_NAME" -o jsonpath='{.status.currentMetrics[?(@.resource.name=="memory")].resource.current.averageUtilization}' 2>/dev/null || true)"

    current_cpu="${current_cpu:-unknown}"
    current_memory="${current_memory:-unknown}"

    echo "HPA cooldown: cpu=${current_cpu}%/${ORIGINAL_CPU_TARGET}% memory=${current_memory}%/${ORIGINAL_MEMORY_TARGET}%"

    if metric_is_below_target "$current_cpu" "$ORIGINAL_CPU_TARGET" && \
      metric_is_below_target "$current_memory" "$ORIGINAL_MEMORY_TARGET"; then
      return 0
    fi

    sleep 10
  done

  return 1
}

cleanup() {
  if [ -n "${LOAD_JOB_NAME:-}" ]; then
    kubectl_cmd delete job -n "$NAMESPACE" "$LOAD_JOB_NAME" --ignore-not-found >/dev/null 2>&1 || true
  fi

  if [ -n "${INITIAL_REPLICAS:-}" ]; then
    echo "Pinning HPA to $INITIAL_REPLICAS replicas for cleanup"
    if patch_hpa_cleanup "$INITIAL_REPLICAS"; then
      HPA_PATCHED=true
    fi

    echo "Restoring deployment/$TARGET_DEPLOYMENT replica count to $INITIAL_REPLICAS"
    kubectl_cmd scale deployment -n "$NAMESPACE" "$TARGET_DEPLOYMENT" --replicas="$INITIAL_REPLICAS" >/dev/null 2>&1 || true
    wait_for_replicas "$INITIAL_REPLICAS" 180 || true
    wait_for_hpa_cooldown 120 || true
  fi

  restore_hpa
}

start_load_job() {
  LOAD_JOB_NAME="pisofire-hpa-load-$(date +%s)"

  kubectl_cmd apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $LOAD_JOB_NAME
  namespace: $NAMESPACE
spec:
  parallelism: $LOAD_WORKERS
  completions: $LOAD_WORKERS
  backoffLimit: 0
  template:
    metadata:
      labels:
        app: pisofire-hpa-load
    spec:
      restartPolicy: Never
      containers:
        - name: load
          image: $SERVICE_CHECK_IMAGE
          imagePullPolicy: IfNotPresent
          env:
            - name: LOAD_TARGET
              value: "$TARGET_DEPLOYMENT"
          command:
            - sh
            - -ec
            - |
              end=\$((\$(date +%s) + $LOAD_DURATION_SECONDS))
              while [ "\$(date +%s)" -lt "\$end" ]; do
                case "\$LOAD_TARGET" in
                  storefront)
                    wget -qO- http://storefront:8000/api/health >/dev/null || true
                    ;;
                  medusa)
                    wget -qO- http://medusa:9000/readyz >/dev/null || true
                    wget -qO- http://medusa:9000/store-readyz >/dev/null || true
                    wget -qO- http://medusa:9000/store/regions >/dev/null || true
                    ;;
                esac
              done
EOF
}

wait_for_scale_up() {
  target_replicas=$((INITIAL_REPLICAS + 1))

  if [ "$target_replicas" -gt "$ORIGINAL_MAX_REPLICAS" ]; then
    target_replicas="$ORIGINAL_MAX_REPLICAS"
  fi

  deadline=$(( $(date +%s) + HPA_TIMEOUT_SECONDS ))

  while [ "$(date +%s)" -lt "$deadline" ]; do
    ready_replicas="$(kubectl_cmd get deployment -n "$NAMESPACE" "$TARGET_DEPLOYMENT" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
    desired_replicas="$(kubectl_cmd get hpa -n "$NAMESPACE" "$HPA_NAME" -o jsonpath='{.status.desiredReplicas}' 2>/dev/null || true)"
    current_cpu="$(kubectl_cmd get hpa -n "$NAMESPACE" "$HPA_NAME" -o jsonpath='{.status.currentMetrics[?(@.resource.name=="cpu")].resource.current.averageUtilization}' 2>/dev/null || true)"
    current_memory="$(kubectl_cmd get hpa -n "$NAMESPACE" "$HPA_NAME" -o jsonpath='{.status.currentMetrics[?(@.resource.name=="memory")].resource.current.averageUtilization}' 2>/dev/null || true)"

    ready_replicas="${ready_replicas:-0}"
    desired_replicas="${desired_replicas:-0}"
    current_cpu="${current_cpu:-unknown}"
    current_memory="${current_memory:-unknown}"

    echo "HPA $HPA_NAME: desired=$desired_replicas ready=$ready_replicas cpu=${current_cpu}% memory=${current_memory}%"

    if [ "$desired_replicas" -ge "$target_replicas" ] || [ "$ready_replicas" -ge "$target_replicas" ]; then
      return 0
    fi

    sleep 10
  done

  return 1
}

require_command kubectl
validate_context
original_targets
validate_target
trap cleanup EXIT INT TERM

kubectl_cmd get hpa -n "$NAMESPACE" "$HPA_NAME" >/dev/null
kubectl_cmd wait -n "$NAMESPACE" --for=condition=available --timeout=180s "deployment/$TARGET_DEPLOYMENT" >/dev/null

if ! kubectl_cmd get --raw /apis/metrics.k8s.io/v1beta1/nodes >/dev/null 2>&1; then
  echo "Kubernetes metrics API is unavailable; HPA cannot scale on CPU/memory." >&2
  exit 1
fi

INITIAL_REPLICAS="$(kubectl_cmd get deployment -n "$NAMESPACE" "$TARGET_DEPLOYMENT" -o jsonpath='{.spec.replicas}')"
INITIAL_REPLICAS="${INITIAL_REPLICAS:-$ORIGINAL_MIN_REPLICAS}"

echo "Starting HPA scale demonstration"
echo "Namespace: $NAMESPACE"
echo "Target deployment: $TARGET_DEPLOYMENT"
echo "HPA: $HPA_NAME"
echo "Initial replicas: $INITIAL_REPLICAS"

if [ "$CONTROLLED_HPA_DEMO" = "true" ]; then
  echo "Temporarily lowering HPA targets to 1% for a deterministic demo."
  patch_hpa "$ORIGINAL_MIN_REPLICAS" "$ORIGINAL_MAX_REPLICAS" 1 1
  HPA_PATCHED=true
fi

echo "Starting in-cluster HTTP load: workers=$LOAD_WORKERS duration=${LOAD_DURATION_SECONDS}s"
start_load_job

if ! wait_for_scale_up; then
  echo "HPA did not request or reach an extra replica before timeout." >&2
  echo "Try increasing LOAD_WORKERS or LOAD_DURATION_SECONDS, or keep CONTROLLED_HPA_DEMO=true." >&2
  exit 1
fi

kubectl_cmd rollout status -n "$NAMESPACE" --timeout=180s "deployment/$TARGET_DEPLOYMENT" >/dev/null

printf '%s\n' "HPA scale test passed" \
  "Namespace: $NAMESPACE" \
  "Target deployment: $TARGET_DEPLOYMENT" \
  "HPA: $HPA_NAME" \
  "Initial replicas: $INITIAL_REPLICAS" \
  "Scale-up observed: yes"
