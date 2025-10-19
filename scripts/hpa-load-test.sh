#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: hpa-load-test.sh [-n namespace] [-u url] [-d duration] [-c concurrency]

Launches a temporary "hey" pod that generates HTTP load against the target
service to trigger the Horizontal Pod Autoscaler. When the run completes, the
pod logs are streamed and the pod is deleted.

Options:
  -n namespace   Kubernetes namespace where the target service lives (default: ginflix)
  -u url         Full service URL to hit from inside the cluster
                 (default: http://ginflix-backend.ginflix.svc.cluster.local:8080/api/videos)
  -d duration    How long the load test should run (default: 3m)
  -c concurrency Number of concurrent workers used by hey (default: 40)
EOF
}

NAMESPACE="ginflix"
TARGET_URL="http://ginflix-backend.ginflix.svc.cluster.local:8080/api/videos"
DURATION="3m"
CONCURRENCY="40"

while getopts ":n:u:d:c:h" opt; do
  case "${opt}" in
    n) NAMESPACE="${OPTARG}" ;;
    u) TARGET_URL="${OPTARG}" ;;
    d) DURATION="${OPTARG}" ;;
    c) CONCURRENCY="${OPTARG}" ;;
    h) usage; exit 0 ;;
    \?) echo "Invalid option: -${OPTARG}" >&2; usage; exit 1 ;;
    :) echo "Option -${OPTARG} requires an argument." >&2; usage; exit 1 ;;
  esac
done

POD_NAME="hpa-load-$(date +%s)"

echo "Starting load pod ${POD_NAME} in namespace ${NAMESPACE}..."
kubectl run "${POD_NAME}" \
  --namespace "${NAMESPACE}" \
  --image=williamyeh/hey \
  --restart=Never \
  -- \
  -z "${DURATION}" \
  -c "${CONCURRENCY}" \
  "${TARGET_URL}"

echo "Waiting for pod ${POD_NAME} to be ready..."
kubectl wait --namespace "${NAMESPACE}" --for=condition=Ready pod/"${POD_NAME}" --timeout=90s >/dev/null

echo "Streaming load results:"
kubectl logs --namespace "${NAMESPACE}" -f "${POD_NAME}"

echo "Cleaning up pod ${POD_NAME}..."
kubectl delete pod "${POD_NAME}" --namespace "${NAMESPACE}" --wait=false >/dev/null
echo "Done."
