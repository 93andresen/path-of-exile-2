#!/usr/bin/env bash
# probe-poe2-endpoints.sh
# One-off, read-only probe of the public PoE2 data endpoints used in
# poe2-stats-sources.md. No credentials, no auth, GET + the trade search POST
# that the official trade site itself performs. Prints status, content-type,
# rate-limit headers and a short body head for each endpoint.
#
# Usage: bash probe-poe2-endpoints.sh [league]
# Default league is taken from /api/trade2/data/leagues (first poe2 entry).

set -u
UA="poe2-stats-research/1.0 (one-off probe; contact: local operator)"
BASE_TRADE="https://www.pathofexile.com/api/trade2"
BASE_API="https://api.pathofexile.com"
NINJA="https://poe.ninja/poe2/api/economy"
SCOUT="https://api.poe2scout.com"
HEAD_BYTES="${HEAD_BYTES:-260}"

enc() { printf '%s' "$1" | sed -e 's/ /%20/g'; }

get() { # get <label> <url> [extra curl args...]
  local label="$1" url="$2"; shift 2
  printf '\n=== %s\n    %s\n' "$label" "$url"
  curl -sS -i -A "$UA" "$@" "$url" \
    | tr -d '\r' \
    | awk 'BEGIN{IGNORECASE=1}
           /^HTTP\//{print "    " $0}
           /^content-type:/{print "    " $0}
           /^x-rate-limit|^retry-after|x-ratelimit/{print "    " $0}
           /^\r?$/ && !body {body=1; next}
           body {print "    " substr($0,1,'"$HEAD_BYTES"'); exit}'
}

printf '== league discovery\n'
LEAGUE="${1:-}"
if [ -z "$LEAGUE" ]; then
  LEAGUE=$(curl -sS -A "$UA" "$BASE_TRADE/data/leagues" \
    | grep -o -E '"id":"[^"]+","realm":"poe2"' | head -1 | sed -E 's/"id":"([^"]+)".*/\1/')
fi
LEAGUE_ENC=$(enc "${LEAGUE:-}")
printf '    league = %s   (encoded: %s)\n' "${LEAGUE:-<none found>}" "$LEAGUE_ENC"

get "trade2 data/leagues"        "$BASE_TRADE/data/leagues"
get "trade2 data/filters"        "$BASE_TRADE/data/filters"
get "trade2 data/stats"          "$BASE_TRADE/data/stats"
get "trade2 data/static"         "$BASE_TRADE/data/static"

printf '\n=== trade2 search (POST, unauthenticated) + fetch round trip\n'
RESP=$(curl -sS -A "$UA" -X POST -H 'Content-Type: application/json' \
  -d '{"query":{"status":{"option":"online"},"stats":[{"type":"and","filters":[]}]},"sort":{"price":"asc"}}' \
  "$BASE_TRADE/search/poe2/$LEAGUE_ENC")
QID=$(printf '%s' "$RESP" | grep -o -E '"id":"[^"]+"' | head -1 | sed -E 's/"id":"([^"]+)"/\1/')
TOTAL=$(printf '%s' "$RESP" | grep -o -E '"total":[0-9]+' | head -1)
IDS=$(printf '%s' "$RESP" | grep -o -E '"result":\[[^]]*\]' | head -1 | tr -d '"' \
  | sed -E 's/result:\[//; s/\]//' | cut -d, -f1-10)
printf '    query id present: %s   %s\n' "${QID:+yes}" "$TOTAL"
if [ -n "${QID:-}" ] && [ -n "${IDS:-}" ]; then
  get "trade2 fetch (first 10 of the query)" "$BASE_TRADE/fetch/$IDS?query=$QID"
else
  printf '    fetch skipped: no query id or no ids returned\n'
fi
get "trade2 exchange (POST body omitted, expect 4xx)" "$BASE_TRADE/exchange/poe2/$LEAGUE_ENC"

printf '\n== official OAuth API, unauthenticated (expect 401)\n'
get "api /league realm=poe2"            "$BASE_API/league?realm=poe2"
get "api /character realm=poe2"         "$BASE_API/character?realm=poe2"
get "api /league/{league}/ladder"       "$BASE_API/league/$LEAGUE_ENC/ladder?realm=poe2&limit=1"
get "api /currency-exchange realm=poe2" "$BASE_API/currency-exchange/poe2"

printf '\n== third-party economy endpoints\n'
get "poe.ninja economy leagues"         "$NINJA/leagues"
get "poe.ninja exchange overview"       "$NINJA/exchange/current/overview?league=$LEAGUE_ENC&type=Currency"
get "poe.ninja stash uniques"           "$NINJA/stash/current/item/overview?league=$LEAGUE_ENC&type=UniqueWeapons"
get "poe2scout /Realms"                 "$SCOUT/Realms"
get "poe2scout /poe2/Leagues"           "$SCOUT/poe2/Leagues"
get "poe2scout /poe2/Leagues/{league}/Items" "$SCOUT/poe2/Leagues/$LEAGUE_ENC/Items"

printf '\n== done\n'
