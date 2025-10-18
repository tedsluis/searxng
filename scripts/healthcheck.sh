#!/usr/bin/env sh
# SearXNG healthcheck
# - Verifies HTML endpoint is reachable
# - Verifies JSON search API works (format=json)
# - Optional: verifies specific engine(s)
#
# Exit codes:
#   0  OK
#   2  Usage error / bad args
#   3  Could not reach endpoint (connection/DNS/TLS)
#   4  HTTP error (non-2xx)
#   5  JSON API disabled / invalid JSON
#   6  Engine check failed (no results or engine error)
#   7  Rate limited (HTTP 429)
#
# Env vars (all optional):
#   SEARXNG_URL   Base URL (default: http://127.0.0.1:8112)
#   QUERY         Query string (default: ping)
#   ENGINES       Comma-separated engine list to force (default: empty = auto)
#   TIMEOUT       Curl max time in seconds (default: 5)
#   RETRIES       Number of retries on network errors (default: 1)
#   IPV           Force IP version: 4 | 6 | auto (default: auto)
#
# Example:
#   SEARXNG_URL=http://127.0.0.1:8112 ./healthcheck.sh

set -eu

SEARXNG_URL="${SEARXNG_URL:-http://127.0.0.1:8112}"
QUERY="${QUERY:-ping}"
ENGINES="${ENGINES:-}"
TIMEOUT="${TIMEOUT:-5}"
RETRIES="${RETRIES:-1}"
IPV="${IPV:-auto}"

# Build curl IP version switch if requested
IPSW=""
case "$IPV" in
  4) IPSW="--ipv4" ;;
  6) IPSW="--ipv6" ;;
  auto) : ;;
  *) echo "ERR: invalid IPV='$IPV' (use 4|6|auto)" >&2; exit 2 ;;
esac

CURL="/usr/bin/curl"
if ! command -v "$CURL" >/dev/null 2>&1; then
  CURL="curl"
fi

# 1) HTML reachability (GET /)
HTML_CODE=$($CURL -sS -o /dev/null -w "%{http_code}" \
  $IPSW --max-time "$TIMEOUT" --retry "$RETRIES" --retry-delay 0 --retry-all-errors \
  "$SEARXNG_URL/")
case "$HTML_CODE" in
  2*) : ;;
  429) echo "WARN: rate limited on HTML endpoint (HTTP 429)"; exit 7 ;;
  *)   echo "ERR: HTML endpoint unhealthy (code=$HTML_CODE) at $SEARXNG_URL/"; exit 4 ;;
esac

# 2) JSON API (GET /search?format=json&q=...)
#    Accept JSON and ensure body has a plausible structure.
JSON_URL="$SEARXNG_URL/search"
q_args="format=json&q=$QUERY"
if [ -n "$ENGINES" ]; then
  q_args="$q_args&engines=$ENGINES"
fi

# Capture body and http code
HTTP_HEADERS_FILE="$(mktemp)"
trap 'rm -f "$HTTP_HEADERS_FILE"' INT TERM EXIT

HTTP_BODY=$($CURL -sS $IPSW \
  --max-time "$TIMEOUT" --retry "$RETRIES" --retry-delay 0 --retry-all-errors \
  -D "$HTTP_HEADERS_FILE" \
  -H "Accept: application/json" \
  --get --data-raw "$q_args" \
  "$JSON_URL" \
  || echo "__CURL_ERROR__")
if [ "$HTTP_BODY" = "__CURL_ERROR__" ]; then
  echo "ERR: network error while calling JSON API"; exit 3
fi

HTTP_CODE=$(awk '/^HTTP/{code=$2} END{print code}' "$HTTP_HEADERS_FILE")
case "$HTTP_CODE" in
  2*) : ;;
  429) echo "WARN: rate limited on JSON API (HTTP 429)"; exit 7 ;;
  *)   echo "ERR: JSON API HTTP $HTTP_CODE at $JSON_URL?$q_args"; exit 4 ;;
esac

# Check content-type looks like JSON
CT=$(awk 'BEGIN{IGNORECASE=1} /^Content-Type:/{print $0}' "$HTTP_HEADERS_FILE" | tr -d '\r')
echo "$CT" | grep -qi 'application/json' || {
  # Some instances return text/plain with JSON body; fall back to body inspection
  :
}

# Basic JSON shape checks (without jq dependency)
# must contain keys "query" and "results" (array)
echo "$HTTP_BODY" | grep -q '"query"' || { echo "ERR: response missing 'query' key — is JSON output enabled?"; exit 5; }
echo "$HTTP_BODY" | grep -q '"results"' || { echo "ERR: response missing 'results' key — is JSON output enabled?"; exit 5; }

# Optional engine sanity check: if ENGINES specified, require at least 1 result
if [ -n "$ENGINES" ]; then
  # Count occurrences of result objects quickly (not strict JSON parsing)
  # look for `"results":[` followed by `{`
  RESULTS_COUNT=$(printf "%s" "$HTTP_BODY" | awk 'BEGIN{RS="{";c=0}/"url":|\"title\":/{c++}END{print c}')
  if [ "$RESULTS_COUNT" -lt 1 ]; then
    echo "ERR: engine(s) '$ENGINES' returned zero results"; exit 6
  fi
fi

echo "OK: SearXNG healthy — HTML up, JSON API up (q='$QUERY' engines='${ENGINES:-auto}')."
exit 0