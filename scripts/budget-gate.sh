#!/usr/bin/env bash
#
# Refuses to deploy a service that's already spent its error budget.
#
#   ./scripts/budget-gate.sh checkout-api availability
#   ./scripts/budget-gate.sh checkout-api availability 0.20
#
# 0 = go, 1 = blocked, 2 = couldn't read the budget. Keeping 1 and 2 separate
# matters: a broken Prometheus shouldn't wave deploys through, and shouldn't
# block them without saying why.

set -euo pipefail

SERVICE="${1:?usage: budget-gate.sh <service> <slo> [min-remaining]}"
SLO="${2:?usage: budget-gate.sh <service> <slo> [min-remaining]}"
MIN_REMAINING="${3:-0.10}"
PROM_URL="${PROM_URL:-http://localhost:9090}"

QUERY="slo:error_budget:remaining_ratio{service=\"${SERVICE}\",slo=\"${SLO}\"}"

response="$(curl -sS -G "${PROM_URL}/api/v1/query" --data-urlencode "query=${QUERY}" || true)"

if [[ -z "${response}" ]]; then
  echo "could not reach Prometheus at ${PROM_URL}" >&2
  exit 2
fi

status="$(jq -r '.status // "error"' <<<"${response}")"
if [[ "${status}" != "success" ]]; then
  echo "query failed: $(jq -r '.error // "unknown error"' <<<"${response}")" >&2
  exit 2
fi

remaining="$(jq -r '.data.result[0].value[1] // empty' <<<"${response}")"
if [[ -z "${remaining}" ]]; then
  echo "no error budget series for ${SERVICE}/${SLO}" >&2
  echo "either the SLO is not defined or the service has never reported metrics" >&2
  exit 2
fi

printf 'service        %s\n' "${SERVICE}"
printf 'slo            %s\n' "${SLO}"
printf 'budget left    %.1f%%\n' "$(awk -v r="${remaining}" 'BEGIN { print r * 100 }')"
printf 'gate threshold %.1f%%\n' "$(awk -v m="${MIN_REMAINING}" 'BEGIN { print m * 100 }')"

if awk -v r="${remaining}" -v m="${MIN_REMAINING}" 'BEGIN { exit !(r < m) }'; then
  cat >&2 <<EOF

blocked: ${SERVICE}/${SLO} does not have enough error budget left to absorb a
bad release. Fix the reliability problem, wait for the window to roll forward,
or override deliberately if this deploy is the fix.
EOF
  exit 1
fi

echo
echo "ok: enough budget left to deploy"
