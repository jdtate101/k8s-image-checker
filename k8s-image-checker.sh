#!/usr/bin/env bash
#
# k8s-image-check.sh
# Report current vs latest image versions for every Deployment / StatefulSet
# (optionally DaemonSets) on a Kubernetes / RKE2 cluster, grouped by namespace.
#
# Requires: bash 4+, kubectl, jq, curl
#
# Usage:
#   ./k8s-image-check.sh                    # all namespaces
#   ./k8s-image-check.sh -n my-namespace    # single namespace
#   ./k8s-image-check.sh -s                 # skip system namespaces
#   ./k8s-image-check.sh -d                 # include DaemonSets
#   ./k8s-image-check.sh -i                 # include init containers
#   ./k8s-image-check.sh -u                 # only show images with updates
#   ./k8s-image-check.sh -j                 # JSON output instead of the visual report
#   ./k8s-image-check.sh -p 300             # max registry tag pages to read (default 100)
#   ./k8s-image-check.sh -k /path/to/kubeconfig -c context
#   ./k8s-image-check.sh --no-color
#
set -uo pipefail

# ---------------------------------------------------------------- options ---
NAMESPACE=""
SKIP_SYSTEM=0
INCLUDE_DS=0
INCLUDE_INIT=0
ONLY_UPDATES=0
KCONFIG=""
KCONTEXT=""
USE_COLOR=1
JSON_OUT=0
MAX_PAGES=100
QUAY_PAGES=15

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace) NAMESPACE="$2"; shift 2 ;;
    -s|--skip-system) SKIP_SYSTEM=1; shift ;;
    -d|--daemonsets) INCLUDE_DS=1; shift ;;
    -i|--init) INCLUDE_INIT=1; shift ;;
    -u|--updates-only) ONLY_UPDATES=1; shift ;;
    -k|--kubeconfig) KCONFIG="$2"; shift 2 ;;
    -c|--context) KCONTEXT="$2"; shift 2 ;;
    -j|--json) JSON_OUT=1; shift ;;
    -p|--max-pages) MAX_PAGES="$2"; shift 2 ;;
    --no-color) USE_COLOR=0; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ----------------------------------------------------------------- checks ---
if (( BASH_VERSINFO[0] < 4 )); then
  echo "bash 4+ is required (associative arrays)." >&2; exit 1
fi
for bin in kubectl jq curl; do
  command -v "$bin" >/dev/null 2>&1 || { echo "Missing dependency: $bin" >&2; exit 1; }
done

# RKE2 default kubeconfig if none supplied
if [[ -z "$KCONFIG" && -z "${KUBECONFIG:-}" && -r /etc/rancher/rke2/rke2.yaml ]]; then
  KCONFIG=/etc/rancher/rke2/rke2.yaml
fi
KUBECTL=(kubectl)
[[ -n "$KCONFIG"  ]] && KUBECTL+=(--kubeconfig "$KCONFIG")
[[ -n "$KCONTEXT" ]] && KUBECTL+=(--context "$KCONTEXT")

# ----------------------------------------------------------------- colours ---
if [[ -t 1 && -z "${NO_COLOR:-}" && $USE_COLOR -eq 1 ]]; then
  RST=$'\e[0m'; BOLD=$'\e[1m'; DIM=$'\e[2m'
  RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; BLU=$'\e[34m'
  MAG=$'\e[35m'; CYN=$'\e[36m'; WHT=$'\e[97m'
  BGCYN=$'\e[46;30m'
else
  RST=""; BOLD=""; DIM=""; RED=""; GRN=""; YEL=""; BLU=""; MAG=""; CYN=""; WHT=""; BGCYN=""
fi

# ------------------------------------------------------------ image parsing ---
REG=""; REPO=""; TAG=""; DIGEST=""

parse_image() {
  local img=$1
  DIGEST=""; TAG=""
  if [[ $img == *@* ]]; then DIGEST=${img#*@}; img=${img%%@*}; fi
  local last=${img##*/}
  if [[ $last == *:* ]]; then TAG=${last#*:}; img=${img%:*}; fi
  local first=${img%%/*}
  if [[ $img == */* && ( $first == *.* || $first == *:* || $first == localhost ) ]]; then
    REG=$first; REPO=${img#*/}
  else
    REG=docker.io; REPO=$img
  fi
  [[ $REG == index.docker.io || $REG == registry-1.docker.io ]] && REG=docker.io
  [[ $REG == docker.io && $REPO != */* ]] && REPO="library/$REPO"
}

# ---------------------------------------------------------- registry lookup ---
# Prints all tags for REG/REPO, one per line. Handles anonymous bearer-token
# auth (Docker Hub, GHCR, Quay, registry.k8s.io, GCR, etc.) and pagination.
# Quay's own API returns tags newest-first, so the latest releases are reached
# quickly even on repos with thousands of tags (the v2 list is not date-ordered).
fetch_tags_quay() {
  local repo=$1 page=1 body more
  while (( page <= QUAY_PAGES )); do
    body=$(curl -s -m 20 "https://quay.io/api/v1/repository/${repo}/tag/?limit=100&page=${page}&onlyActiveTags=true") || { (( page > 1 )) && break; return 1; }
    if ! jq -e '.tags' <<<"$body" >/dev/null 2>&1; then
      (( page > 1 )) && break
      return 1
    fi
    jq -r '.tags[]?.name' <<<"$body"
    more=$(jq -r '.has_additional // false' <<<"$body")
    [[ $more == true ]] || break
    page=$((page + 1))
  done
  return 0
}

fetch_tags() {
  local reg=$1 repo=$2 host=$1
  if [[ $reg == quay.io ]]; then
    local qout
    if qout=$(fetch_tags_quay "$repo") && [[ -n $qout ]]; then
      printf '%s\n' "$qout"; return 0
    fi
  fi
  [[ $reg == docker.io ]] && host=registry-1.docker.io
  local url="https://${host}/v2/${repo}/tags/list?n=1000"
  local token="" pages=0 hdr body code auth realm service scope next

  while [[ -n $url && $pages -lt $MAX_PAGES ]]; do
    hdr=$(mktemp)
    if [[ -n $token ]]; then
      body=$(curl -s -m 20 -D "$hdr" -H "Authorization: Bearer $token" "$url")
    else
      body=$(curl -s -m 20 -D "$hdr" "$url")
    fi
    code=$(awk 'NR==1{print $2}' "$hdr")

    if [[ $code == 401 && -z $token ]]; then
      auth=$(grep -i '^www-authenticate:' "$hdr" | tr -d '\r')
      realm=$(sed -n 's/.*[Rr]ealm="\([^"]*\)".*/\1/p' <<<"$auth")
      service=$(sed -n 's/.*[Ss]ervice="\([^"]*\)".*/\1/p' <<<"$auth")
      rm -f "$hdr"
      [[ -z $realm ]] && return 1
      scope="repository:${repo}:pull"
      token=$(curl -s -m 20 -G "$realm" \
                --data-urlencode "service=${service}" \
                --data-urlencode "scope=${scope}" \
              | jq -r '.token // .access_token // empty' 2>/dev/null)
      [[ -z $token ]] && return 1
      continue
    fi

    if [[ $code != 200 ]]; then rm -f "$hdr"; return 1; fi

    jq -r '.tags[]?' <<<"$body" 2>/dev/null
    next=$(grep -i '^link:' "$hdr" | tr -d '\r' | sed -n 's/.*<\([^>]*\)>.*rel="next".*/\1/p')
    rm -f "$hdr"
    if [[ -n $next ]]; then
      [[ $next == http* ]] && url=$next || url="https://${host}${next}"
    else
      url=""
    fi
    pages=$((pages + 1))
  done
  return 0
}

declare -A TAGCACHE=()

get_tags_cached() {
  local key="$1/$2" out
  if [[ -z ${TAGCACHE[$key]+x} ]]; then
    [[ -t 2 ]] && printf '\r\e[K  querying %s ...' "$key" >&2
    if out=$(fetch_tags "$1" "$2") && out=$(grep -E '^v?[0-9]' <<<"$out") && [[ -n $out ]]; then
      TAGCACHE[$key]=$out
    else
      TAGCACHE[$key]="__FAIL__"
    fi
    [[ -t 2 ]] && printf '\r\e[K' >&2
  fi
  printf '%s' "${TAGCACHE[$key]}"
}

# ------------------------------------------------------- version comparison ---
# analyze CURRENT_TAG TAGS  ->  sets LATEST and STATE
#   STATE: current | patch | minor | major | floating | unknown | nolookup
LATEST=""; STATE=""

analyze() {
  local cur=$1 tags=$2
  LATEST=""; STATE="unknown"

  if [[ -z $cur || $cur == latest || $cur == stable || $cur == main || $cur == master ]]; then
    STATE="floating"; return
  fi
  if [[ ! $cur =~ ^(v?)([0-9]+(\.[0-9]+)*)(.*)$ ]]; then
    STATE="unknown"; return
  fi
  local prefix=${BASH_REMATCH[1]} nums=${BASH_REMATCH[2]} suffix=${BASH_REMATCH[4]}
  local ncomp; ncomp=$(awk -F. '{print NF}' <<<"$nums")

  # Candidate tags must share the same shape: prefix, N numeric parts, suffix
  local esuffix; esuffix=$(sed 's/[][\.^$*+?(){}|/]/\\&/g' <<<"$suffix")
  local re="^${prefix}[0-9]+(\.[0-9]+){$((ncomp - 1))}${esuffix}\$"

  local best
  best=$(grep -E "$re" <<<"$tags" | sed "s/^${prefix}//; s/${esuffix}\$//" \
         | sort -V | tail -n1)
  if [[ -z $best ]]; then STATE="unknown"; return; fi

  LATEST="${prefix}${best}${suffix}"
  local newest
  newest=$(printf '%s\n%s\n' "$nums" "$best" | sort -V | tail -n1)

  if [[ $best == "$nums" || $newest == "$nums" ]]; then
    STATE="current"; LATEST="$cur"; return
  fi

  local cmaj=${nums%%.*} lmaj=${best%%.*}
  local crest=${nums#*.} lrest=${best#*.}
  local cmin=${crest%%.*} lmin=${lrest%%.*}
  if [[ $cmaj != "$lmaj" ]]; then
    STATE="major"
  elif [[ $ncomp -ge 2 && $cmin != "$lmin" ]]; then
    STATE="minor"
  else
    STATE="patch"
  fi
}

# ------------------------------------------------------------------ helpers ---
pad() { printf '%-*s' "$2" "$1"; }

trunc() { # trunc STRING MAXLEN
  local s=$1 m=$2
  (( ${#s} > m )) && s="${s:0:$((m - 1))}…"
  printf '%s' "$s"
}

TERM_W=$(tput cols 2>/dev/null || echo 100)
(( TERM_W > 120 )) && TERM_W=120
rule() { local i; for ((i = 0; i < TERM_W; i++)); do printf '%s' "$1"; done; }

# --------------------------------------------------------------- data fetch ---
KINDS="deployments,statefulsets"
(( INCLUDE_DS )) && KINDS="deployments,statefulsets,daemonsets"

NS_ARGS=(-A)
[[ -n $NAMESPACE ]] && NS_ARGS=(-n "$NAMESPACE")

if ! RAW=$("${KUBECTL[@]}" get "$KINDS" "${NS_ARGS[@]}" -o json 2>&1); then
  echo "${RED}kubectl failed:${RST} $RAW" >&2
  exit 1
fi

INIT_JQ='[]'
(( INCLUDE_INIT )) && INIT_JQ='(.spec.template.spec.initContainers // [])'

ROWS=$(jq -r --argjson init "$INCLUDE_INIT" '
  .items[] |
  [ .metadata.namespace,
    .kind,
    .metadata.name,
    (if .kind == "DaemonSet" then "ds" else ((.spec.replicas // 1) | tostring) end),
    ( ( (if $init == 1 then (.spec.template.spec.initContainers // []) | map("init|" + .name + "|" + .image) else [] end)
        + (.spec.template.spec.containers | map("app|" + .name + "|" + .image)) )
      | join(";") )
  ] | @tsv' <<<"$RAW" | sort -t$'\t' -k1,1 -k2,2 -k3,3)

if [[ -z $ROWS ]]; then
  echo "No workloads found."; exit 0
fi

is_system_ns() {
  case "$1" in
    kube-system|kube-public|kube-node-lease|cattle-system|cattle-fleet-system|\
cattle-fleet-local-system|cattle-fleet-clusters-system|cattle-impersonation-system|\
cattle-provisioning-capi-system|cattle-global-data|cattle-global-nt|local|fleet-*) return 0 ;;
  esac
  return 1
}

# ------------------------------------------------------------------ output ---
JSON_TMP=""
if (( JSON_OUT )); then
  JSON_TMP=$(mktemp); trap 'rm -f "$JSON_TMP"' EXIT
  exec 3>&1 1>/dev/null     # human report is discarded, JSON goes to fd 3
fi
CLUSTER=$("${KUBECTL[@]}" config current-context 2>/dev/null || echo "unknown")
echo
echo "${BOLD}${WHT}$(rule '═')${RST}"
echo "${BOLD}${WHT}  Kubernetes image version report${RST}   ${DIM}context: ${CLUSTER}  |  $(date '+%Y-%m-%d %H:%M')${RST}"
echo "${BOLD}${WHT}$(rule '═')${RST}"
echo "  Legend: ${GRN}✔ up to date${RST}   ${YEL}⬆ patch/minor update${RST}   ${RED}⚠ major update${RST}   ${BLU}● floating tag / digest${RST}   ${MAG}? unable to check${RST}"

T_IMG=0; T_CUR=0; T_PATCH=0; T_MINOR=0; T_MAJOR=0; T_FLOAT=0; T_UNK=0
LAST_NS=""
declare -a NS_BUFFER=()

W_NAME=24; W_VER=22

while IFS=$'\t' read -r ns kind name reps containers; do
  (( SKIP_SYSTEM )) && is_system_ns "$ns" && continue

  # Evaluate every container for this workload first so we can honour -u
  lines=()
  recs=()
  show_workload=0
  IFS=';' read -ra ents <<<"$containers"
  total=${#ents[@]}
  idx=0
  for ent in "${ents[@]}"; do
    idx=$((idx + 1))
    ctype=${ent%%|*}; rest=${ent#*|}
    cname=${rest%%|*}; image=${rest#*|}

    parse_image "$image"
    T_IMG=$((T_IMG + 1))

    cur_disp=${TAG:-<none>}
    lat_disp="-"; icon=""; label=""; colour=$RST

    if [[ -n $DIGEST && -z $TAG ]]; then
      STATE="floating"; cur_disp="@${DIGEST:7:12}"
    elif [[ ! $TAG =~ ^v?[0-9] ]]; then
      # no tag, latest, stable, main, custom names (cfe-demo, stable-alpine...)
      STATE="floating"; [[ -z $TAG ]] && cur_disp="latest (implicit)"
    else
      tags=$(get_tags_cached "$REG" "$REPO")
      if [[ $tags == "__FAIL__" ]]; then
        STATE="nolookup"
      else
        analyze "$TAG" "$tags"
      fi
    fi

    case $STATE in
      current)  icon="✔"; label="up to date";     colour=$GRN; lat_disp=$LATEST; T_CUR=$((T_CUR+1)) ;;
      patch)    icon="⬆"; label="patch update";   colour=$YEL; lat_disp=$LATEST; T_PATCH=$((T_PATCH+1)); show_workload=1 ;;
      minor)    icon="⬆"; label="minor update";   colour=$YEL; lat_disp=$LATEST; T_MINOR=$((T_MINOR+1)); show_workload=1 ;;
      major)    icon="⚠"; label="MAJOR update";   colour=$RED; lat_disp=$LATEST; T_MAJOR=$((T_MAJOR+1)); show_workload=1 ;;
      floating) icon="●"; label="floating/pinned"; colour=$BLU; lat_disp="n/a";   T_FLOAT=$((T_FLOAT+1)) ;;
      nolookup) icon="?"; label="registry lookup failed"; colour=$MAG; T_UNK=$((T_UNK+1)) ;;
      *)        icon="?"; label="no comparable tags"; colour=$MAG; T_UNK=$((T_UNK+1)) ;;
    esac

    if (( JSON_OUT )); then
      recs+=("$(jq -nc --arg ns "$ns" --arg kind "$kind" --arg workload "$name" \
        --arg container "$cname" --argjson init "$([[ $ctype == init ]] && echo true || echo false)" \
        --arg image "$image" --arg current "$cur_disp" --arg latest "$lat_disp" --arg status "$STATE" \
        '{namespace:$ns,kind:$kind,workload:$workload,container:$container,init:$init,image:$image,current:$current,latest:$latest,status:$status}')")
    fi
    [[ $ctype == init ]] && cname="${cname} (init)"
    branch="├─"; cont="│ "
    (( idx == total )) && { branch="└─"; cont="  "; }

    lines+=("  ${DIM}${branch}${RST} ${BOLD}$(pad "$(trunc "$cname" $W_NAME)" $W_NAME)${RST} ${colour}$(pad "$(trunc "$cur_disp" $W_VER)" $W_VER)${RST} ${DIM}→${RST} ${colour}${BOLD}$(pad "$(trunc "$lat_disp" $W_VER)" $W_VER)${RST} ${colour}${icon} ${label}${RST}")
    lines+=("  ${DIM}${cont}   ${REG}/${REPO}${RST}")
  done

  if (( ONLY_UPDATES )) && (( ! show_workload )); then
    continue
  fi
  (( JSON_OUT )) && printf '%s\n' "${recs[@]}" >> "$JSON_TMP"

  if [[ $ns != "$LAST_NS" ]]; then
    echo
    echo "${BGCYN}${BOLD}  NAMESPACE  ${RST} ${BOLD}${CYN}${ns}${RST}"
    echo "${CYN}$(rule '─')${RST}"
    LAST_NS=$ns
  fi

  case $kind in
    Deployment)  kcol=$GRN;  kshort="Deployment " ;;
    StatefulSet) kcol=$MAG;  kshort="StatefulSet" ;;
    DaemonSet)   kcol=$YEL;  kshort="DaemonSet  " ;;
    *)           kcol=$WHT;  kshort=$kind ;;
  esac
  repinfo=""
  [[ $reps != ds ]] && repinfo="${DIM} (replicas: ${reps})${RST}"
  echo " ${kcol}${BOLD}▌${kshort}${RST} ${BOLD}${WHT}${name}${RST}${repinfo}"
  printf '%s\n' "${lines[@]}"
done <<<"$ROWS"

# ----------------------------------------------------------------- summary ---
echo
echo "${BOLD}${WHT}$(rule '═')${RST}"
echo "${BOLD}  Summary${RST}  ${DIM}(${T_IMG} images checked)${RST}"
echo "  ${GRN}✔ Up to date      : ${T_CUR}${RST}"
echo "  ${YEL}⬆ Patch updates   : ${T_PATCH}${RST}"
echo "  ${YEL}⬆ Minor updates   : ${T_MINOR}${RST}"
echo "  ${RED}⚠ Major updates   : ${T_MAJOR}${RST}"
echo "  ${BLU}● Floating/pinned : ${T_FLOAT}${RST}"
echo "  ${MAG}? Unable to check : ${T_UNK}${RST}"
echo "${BOLD}${WHT}$(rule '═')${RST}"
echo
if (( JSON_OUT )); then
  jq -s '.' "$JSON_TMP" >&3
fi
