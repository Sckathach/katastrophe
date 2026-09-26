#!/usr/bin/env bash
# bases.sh — `kata bases`: the warm-base inventory, plus what `ls` cannot say:
# what each base was baked from, whether that parent has moved on (STALE), and
# whether it trusts the CA running now (CA DRIFT).
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck disable=SC1091
source "${HERE}/../config.sh"

cmd_bases() {
  echo "bases in ${VM_BASES_DIR}"
  [[ -d "$VM_BASES_DIR" ]] || {
    warn "${VM_BASES_DIR} missing — nothing built yet (kata build-base)"
    return 0
  }
  shopt -s nullglob
  local imgs=("$VM_BASES_DIR"/*.qcow2)
  shopt -u nullglob
  ((${#imgs[@]})) || {
    info "no bases in ${VM_BASES_DIR}"
    echo "  build the blank one: kata build-base"
    return 0
  }

  # Current versions first: a child's sidecar records its parent's version at
  # bake time, and the gap is what STALE means.
  declare -A cur=()
  local img name
  for img in "${imgs[@]}"; do
    name="$(basename "$img" .qcow2)"
    cur["$name"]="$(base_version "$name")"
  done

  local stale=0 drift=0 host_ca
  host_ca="$(ca_fingerprint)"
  echo
  printf "  %-14s %4s  %7s  %-17s %s\n" NAME VER SIZE CREATED FROM
  for img in "${imgs[@]}"; do
    name="$(basename "$img" .qcow2)"
    local meta="${VM_BASES_DIR}/${name}.json" ver created from
    if [[ -r "$meta" ]] && command -v jq >/dev/null; then
      ver="v$(jq -r '.version // "?"' "$meta")"
      created="$(jq -r '.created // ""' "$meta" | tr T ' ' | cut -c1-16)"
      local pn pv
      pn="$(jq -r '.parent.name // empty' "$meta")"
      pv="$(jq -r '.parent.version // empty' "$meta")"
      if [[ -n "$pn" ]]; then
        from="← ${pn} v${pv}"
        if [[ -n "${cur[$pn]:-}" ]] && ((cur[$pn] > pv)); then
          from="${from}   ${_C_WARN}STALE: ${pn} is now v${cur[$pn]}${_C_OFF}"
          stale=1
        fi
      elif [[ "$(jq -r '.origin // empty' "$meta")" == build ]]; then
        from="built from the Ubuntu cloud image"
      else
        from="—"
      fi
      # A base trusting an old CA fails every TLS request in the guest. Empty
      # on either side is unknown, never drift.
      local bca
      bca="$(jq -r '.ca // ""' "$meta")"
      if [[ -n "$bca" && -n "$host_ca" && "$bca" != "$host_ca" ]]; then
        from="${from}   ${_C_ERR}CA DRIFT${_C_OFF}"
        drift=1
      fi
    else
      # Normal, never fatal: anything baked before versioning existed.
      ver="?" created="—" from="unversioned (baked before metadata existed)"
    fi
    printf "  %-14s %4s  %7s  %-17s %s\n" \
      "$name" "$ver" "$(human_size "$(stat -c %s "$img")")" "$created" "$from"
  done

  if ((stale)); then
    echo
    warn "a base is older than what it was built from — re-bake: kata vm --ssh --from <parent> --to <name>"
  fi
  if ((drift)); then
    echo
    err "a base trusts a CA this host no longer runs — TLS fails in the guest. Rebuild: kata build-base"
  fi
  # A running --to session bakes only at poweroff; until then the row is the OLD base.
  local to
  if session_alive; then
    to="$(state_field to)"
    if [[ -n "$to" ]]; then
      echo
      info "a session is running with --to ${to}: the row above is still the OLD ${to}. The bake happens on clean poweroff."
    fi
  fi
}

cmd_bases
