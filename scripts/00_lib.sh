#!/usr/bin/env bash
# Shared helpers. Source this file, do not run it.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO/.env}"
# shellcheck disable=SC1090
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

: "${AVN_PROJECT:?Set AVN_PROJECT in .env (copy .env.example)}"
: "${CLOUD:=google-europe-west1}"
: "${PLAN:=startup-4}"
: "${SRC_SERVICE:=pg-source-15}"
: "${SRC_VERSION:=15}"
: "${DST_SERVICE:=pg-target-18}"
: "${DST_VERSION:=18}"
: "${DBNAME:=shop}"
: "${PUBLICATION:=pub_shop_all}"
: "${SUBSCRIPTION:=sub_shop_from_pg15}"
: "${SLOT:=slot_shop_to_pg18}"
: "${SOURCE_IS_AIVEN:=true}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH" >&2; exit 1; }; }
need avn; need jq; need psql

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  OK  %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m  !!  %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Connection helpers. We read host/port/user/password from the Aiven API once
# per service and cache it in a shell variable to avoid hammering the API.
# ---------------------------------------------------------------------------
declare -A _PARAMS

_load_params() { # service
  local svc="$1"
  [[ -n "${_PARAMS[$svc]:-}" ]] && return
  _PARAMS[$svc]="$(avn service get --project "$AVN_PROJECT" --json "$svc" \
      | jq -c '.connection_info.pg_params[0] | {host, port, user, password}')"
  [[ -z "${_PARAMS[$svc]}" || "${_PARAMS[$svc]}" == "null" ]] && die "Could not read connection params for $svc"
}

param() { # service key
  _load_params "$1"; jq -r ".$2" <<<"${_PARAMS[$1]}"
}

# postgres:// URI for a service + database
svc_uri() { # service dbname
  if [[ "$1" == "$SRC_SERVICE" && "$SOURCE_IS_AIVEN" != "true" ]]; then
    : "${SRC_URI:?SOURCE_IS_AIVEN=false requires SRC_URI in .env}"
    echo "$SRC_URI"; return
  fi
  printf 'postgres://%s:%s@%s:%s/%s?sslmode=require' \
    "$(param "$1" user)" "$(param "$1" password)" "$(param "$1" host)" "$(param "$1" port)" "$2"
}

# key=value conninfo, the format CREATE SUBSCRIPTION wants
svc_conninfo() { # service dbname
  if [[ "$1" == "$SRC_SERVICE" && "$SOURCE_IS_AIVEN" != "true" ]]; then
    : "${SRC_URI:?SOURCE_IS_AIVEN=false requires SRC_URI in .env}"
    echo "$SRC_URI"; return   # libpq accepts a URI here as well
  fi
  printf 'host=%s port=%s dbname=%s user=%s password=%s sslmode=require' \
    "$(param "$1" host)" "$(param "$1" port)" "$2" "$(param "$1" user)" "$(param "$1" password)"
}

# psql wrappers: psql_src / psql_dst [extra psql args...]; database via PSQL_DB (default $DBNAME)
_psql() { local svc="$1" db="$2"; shift 2; psql "$(svc_uri "$svc" "$db")" -X -v ON_ERROR_STOP=1 "$@"; }
psql_src() { _psql "$SRC_SERVICE" "${PSQL_DB:-$DBNAME}" "$@"; }
psql_dst() { _psql "$DST_SERVICE" "${PSQL_DB:-$DBNAME}" "$@"; }

# scalar query helpers (tuples only, unaligned)
q_src() { psql_src -qtA -c "$1"; }
q_dst() { psql_dst -qtA -c "$1"; }

confirm() { # message
  read -r -p "$1 [y/N] " ans; [[ "${ans:-}" =~ ^[Yy]$ ]] || die "Aborted."
}
