#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: verify-hpa.sh [-n namespace]

Asserts that required Horizontal Pod Autoscalers are present and healthy.
Checks include:
  * Metrics API availability.
  * HPA existence with expected min/max replicas.
  * ScalingActive=True condition.
  * Availability of current CPU utilization metrics.

Options:
  -n namespace   Namespace containing the Ginflix resources (default: ginflix).
EOF
}

NAMESPACE="ginflix"
while getopts ":n:h" opt; do
  case "${opt}" in
    n) NAMESPACE="${OPTARG}" ;;
    h) usage; exit 0 ;;
    \?) echo "Invalid option: -${OPTARG}" >&2; usage; exit 1 ;;
    :) echo "Option -${OPTARG} requires an argument." >&2; usage; exit 1 ;;
  esac
done

command -v kubectl >/dev/null 2>&1 || {
  echo "kubectl is required on PATH" >&2
  exit 1
}

wait_for_metrics_api() {
  echo "Waiting for metrics API to become available..."
  for _ in {1..12}; do
    if kubectl top nodes >/dev/null 2>&1; then
      echo "Metrics API is reachable."
      return 0
    fi
    sleep 10
  done
  echo "Timed out waiting for metrics API." >&2
  return 1
}

get_condition_status() {
  local hpa=$1
  local condition=$2
  kubectl get hpa "${hpa}" -n "${NAMESPACE}" \
    -o jsonpath="{range .status.conditions[*]}{.type}={.status}{'\n'}{end}" |
    awk -F '=' -v cond="${condition}" '$1 == cond { print $2 }'
}

wait_for_condition() {
  local hpa=$1
  local condition=$2
  local expected=$3
  echo "Waiting for ${condition}=${expected} on ${hpa}..."
  for _ in {1..12}; do
    local status
    status=$(get_condition_status "${hpa}" "${condition}")
    if [[ "${status}" == "${expected}" ]]; then
      echo "Condition ${condition}=${expected} satisfied."
      return 0
    fi
    sleep 10
  done
  echo "Timed out waiting for ${condition}=${expected} on ${hpa}." >&2
  return 1
}

wait_for_metric() {
  local hpa=$1
  echo "Waiting for current CPU utilization metric on ${hpa}..."
  for _ in {1..12}; do
    local utilization
    utilization=$(kubectl get hpa "${hpa}" -n "${NAMESPACE}" \
      -o jsonpath="{.status.currentMetrics[0].resource.current.averageUtilization}" 2>/dev/null || true)
    if [[ -n "${utilization}" ]]; then
      echo "Current CPU utilization reported: ${utilization}%"
      return 0
    fi
    sleep 10
  done
  echo "Timed out waiting for CPU metrics on ${hpa}." >&2
  return 1
}

validate_hpa() {
  local hpa=$1 expected_min=$2 expected_max=$3
  echo "Validating HPA ${hpa}..."

  kubectl get hpa "${hpa}" -n "${NAMESPACE}" >/dev/null

  local min max current
  min=$(kubectl get hpa "${hpa}" -n "${NAMESPACE}" -o jsonpath="{.spec.minReplicas}")
  max=$(kubectl get hpa "${hpa}" -n "${NAMESPACE}" -o jsonpath="{.spec.maxReplicas}")
  current=$(kubectl get hpa "${hpa}" -n "${NAMESPACE}" -o jsonpath="{.status.currentReplicas}")

  if [[ "${min}" != "${expected_min}" ]]; then
    echo "Unexpected minReplicas for ${hpa}: got ${min}, expected ${expected_min}" >&2
    return 1
  fi

  if [[ "${max}" != "${expected_max}" ]]; then
    echo "Unexpected maxReplicas for ${hpa}: got ${max}, expected ${expected_max}" >&2
    return 1
  fi

  if [[ -z "${current}" ]]; then
    echo "Current replica count missing for ${hpa}" >&2
    return 1
  fi

  if (( current < expected_min )); then
    echo "Current replicas (${current}) lower than minReplicas (${expected_min}) for ${hpa}" >&2
    return 1
  fi

  wait_for_condition "${hpa}" "ScalingActive" "True"
  wait_for_metric "${hpa}"
}

wait_for_metrics_api

validate_hpa "ginflix-backend" 3 6
validate_hpa "ginflix-streamer" 3 6

echo "HPAs validated successfully."
kubectl get hpa -n "${NAMESPACE}"
