#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/publish.sh [options] [box1 box2 ...]

Publishes built boxes from output-<box>/package.box to Vagrant Cloud.

By default, if VERSION is not provided, the script uses the latest locally
installed version for the box (as shown by `vagrant box list`).

The local version is treated as the source of truth; the script will publish
that exact version to Vagrant Cloud.

Options:
  --namespace <name>     Vagrant Cloud namespace (required unless VAGRANT_CLOUD_NAMESPACE is set)
  --provider <name>      Provider name (default: libvirt)
  --arch <name>          Architecture name (default: amd64)
  --version <x.y.z>      Force version (bypasses local version lookup)
  --[no-]build           Build boxes before upload (default: build)
  --rebuild              Force rebuild even if package exists
  --[no-]release         Release the version after upload (default: release)
  --dry-run              Print actions without calling the API
  -h, --help             Show help

Environment:
  HCP_ACCESS_TOKEN             Optional. If set, used as Bearer token.
  VAGRANT_CLOUD_BASE_URL       Optional. Default: https://vagrantcloud.com
  VAGRANT_CLOUD_NAMESPACE      Optional. Overrides --namespace.
  VAGRANT_CLOUD_PROVIDER       Optional. Overrides --provider.
  VAGRANT_CLOUD_ARCH           Optional. Overrides --arch.
  VAGRANT_CLOUD_VERSION        Optional. Overrides --version.
EOF
}

log() { printf '%s\n' "${*}" >&2; }

die() {
  log "ERROR: ${*}"
  exit 1
}

require_cmd() {
  command -v "${1}" >/dev/null 2>&1 || die "Missing required command: ${1}"
}

BASE_URL="${VAGRANT_CLOUD_BASE_URL:-https://vagrantcloud.com}"
TOKEN=""
TOKEN_SOURCE="" # env|hcp
NAMESPACE="${VAGRANT_CLOUD_NAMESPACE:-}"
PROVIDER="${VAGRANT_CLOUD_PROVIDER:-libvirt}"
ARCH="${VAGRANT_CLOUD_ARCH:-}"
VERSION="${VAGRANT_CLOUD_VERSION:-}"

DO_BUILD=1
DO_RELEASE=1
REBUILD=0
DRY_RUN=0

# Globals set by vc_request
VC_HTTP_CODE=""
VC_BODY=""

# Global set by get_upload_path (avoid command substitution subshell issues)
UPLOAD_PATH=""

LATEST_REMOTE_VERSION=""

get_local_latest_version() {
  local box_fqdn="${1}"     # e.g. example/fedora-43
  local provider="${2}"     # e.g. libvirt
  local arch="${3}"         # e.g. amd64

  # Vagrant's machine-readable output emits one box entry as a sequence of
  # events (box-name/provider/version/architecture). Extract matching entries
  # and pick the highest version with sort -V.
  vagrant box list --machine-readable 2>/dev/null \
    | awk -F',' -v want_name="${box_fqdn}" -v want_provider="${provider}" -v want_arch="${arch}" '
        $3=="box-name"{name=$4}
        $3=="box-provider"{prov=$4}
        $3=="box-version"{ver=$4}
        $3=="box-architecture"{
          a=$4
          if(name==want_name && prov==want_provider){
            if(want_arch=="" || a==want_arch || a=="n/a" || a=="unknown" || a==""){
              print ver
            }
          }
          name=""; prov=""; ver=""; a=""
        }
      ' \
    | sort -V \
    | tail -n1 \
    | trim_one_line
}

trim_one_line() {
  tr -d '\r\n'
}

resolve_token() {
  # 1) Explicit HCP access token
  if [[ -n "${HCP_ACCESS_TOKEN:-}" ]]; then
    TOKEN="${HCP_ACCESS_TOKEN}"
    TOKEN_SOURCE="env"
    return 0
  fi

  # 2) HCP CLI token (requires prior auth)
  if command -v hcp >/dev/null 2>&1; then
    local t
    t="$(hcp auth print-access-token 2>/dev/null | trim_one_line || true)"
    if [[ -n "${t}" ]]; then
      TOKEN="${t}"
      TOKEN_SOURCE="hcp"
      return 0
    fi
  fi

  die "No auth token found. Authenticate with HCP and use 'hcp auth print-access-token' (or set HCP_ACCESS_TOKEN)."
}

is_invalid_jwt_error() {
  # Heuristics: HCP/Vagrant responses typically include "invalid JWT".
  # Avoid depending on exact JSON shape.
  local body="${1}"
  [[ "${body}" == *"invalid JWT"* || "${body}" == *"expired"* || "${body}" == *"token"*"invalid"* ]]
}

vc_url() {
  local path="${1}"
  printf '%s%s' "${BASE_URL}" "${path}"
}

vc_request() {
  local method="${1}"
  local path="${2}"
  local data="${3-}"

  local url
  url="$(vc_url "${path}")"

  if [[ "${DRY_RUN}" == "1" ]]; then
    log "DRY-RUN: ${method} ${url}"
    if [[ -n "${data}" ]]; then
      log "DRY-RUN: payload: ${data}"
    fi
    VC_HTTP_CODE="000"
    VC_BODY="{}"
    return 0
  fi

  local attempt
  attempt=1

  while true; do
    local resp
    local auth_args=()
    auth_args=(-H "Authorization: Bearer ${TOKEN}")

    if [[ -n "${data}" ]]; then
      resp="$(curl -sS -L -X "${method}" -H 'Content-Type: application/json' "${auth_args[@]}" --data "${data}" "${url}" -w '\n%{http_code}')"
    else
      resp="$(curl -sS -L -X "${method}" -H 'Content-Type: application/json' "${auth_args[@]}" "${url}" -w '\n%{http_code}')"
    fi

    VC_HTTP_CODE="${resp##*$'\n'}"
    VC_BODY="${resp%$'\n'*}"

    # Auto-refresh token once if it expired mid-run.
    if [[ "${VC_HTTP_CODE}" == "401" && ${attempt} -eq 1 && "${TOKEN_SOURCE}" == "hcp" && "${HCP_ACCESS_TOKEN:-}" == "" ]]; then
      if is_invalid_jwt_error "${VC_BODY}"; then
        log "Auth token expired; refreshing via HCP CLI and retrying ${method} ${path}"
        resolve_token
        attempt=2
        continue
      fi
    fi

    break
  done
}

py_json_scan_max_patch_for_day() {
  local day="${1}" # YYYYMMDD
  python3 - "${day}" <<'PY'
import json
import re
import sys

day = sys.argv[1]
text = sys.stdin.read()
try:
  obj = json.loads(text) if text.strip() else {}
except Exception:
  print(-1)
  raise SystemExit(0)

pattern = re.compile(r"^(\d{8})\.0\.(\d+)$")
max_patch = -1

def walk(v):
  global max_patch
  if isinstance(v, dict):
    for k, vv in v.items():
      if k == "version" and isinstance(vv, str):
        m = pattern.match(vv)
        if m and m.group(1) == day:
          max_patch = max(max_patch, int(m.group(2)))
      walk(vv)
  elif isinstance(v, list):
    for vv in v:
      walk(vv)

walk(obj)
print(max_patch)
PY
}

py_json_get_field() {
  local field="${1}"
  python3 - "${field}" <<'PY'
import json
import sys

field = sys.argv[1]
text = sys.stdin.read()
try:
  obj = json.loads(text)
except Exception:
  print("")
  raise SystemExit(0)

val = obj.get(field, "") if isinstance(obj, dict) else ""
if val is None:
  val = ""
print(val)
PY
}

py_json_get_latest_version_v1() {
  # Reads Vagrant Cloud v1 box JSON and prints the latest available version.
  # Prefers versions that are not obviously unreleased/revoked when status is present.
  python3 - <<'PY'
import json
import re
import sys

text = sys.stdin.read()
try:
  obj = json.loads(text) if text.strip() else {}
except Exception:
  print("")
  raise SystemExit(0)

versions = obj.get("versions") if isinstance(obj, dict) else None
if not isinstance(versions, list):
  print("")
  raise SystemExit(0)

semver = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")
bad_status = {"unreleased", "revoked", "deleted", "inactive"}

def key(v: str):
  m = semver.match(v)
  if not m:
    return None
  return (int(m.group(1)), int(m.group(2)), int(m.group(3)))

candidates = []
for item in versions:
  if not isinstance(item, dict):
    continue
  v = item.get("version")
  if not isinstance(v, str):
    continue
  k = key(v)
  if k is None:
    continue
  status = item.get("status")
  if isinstance(status, str) and status.lower() in bad_status:
    continue
  candidates.append((k, v))

if not candidates:
  print("")
else:
  candidates.sort()
  print(candidates[-1][1])
PY
}

py_regex_max_patch_for_day() {
  # Robust fallback: scan raw text for occurrences of YYYYMMDD.0.<patch>
  # and return the maximum patch found for that day, or -1.
  local day="${1}"
  python3 - "${day}" <<'PY'
import re
import sys

day = sys.argv[1]
text = sys.stdin.read() or ""

pattern = re.compile(r"\b" + re.escape(day) + r"\.0\.(\d+)\b")
max_patch = -1
for m in pattern.finditer(text):
  try:
    max_patch = max(max_patch, int(m.group(1)))
  except Exception:
    pass

print(max_patch)
PY
}

py_regex_latest_semver() {
  # Robust fallback: scan raw text for semver-looking strings and return the max.
  python3 - <<'PY'
import re
import sys

text = sys.stdin.read() or ""
pattern = re.compile(r"\b(\d+)\.(\d+)\.(\d+)\b")

best = None
best_str = ""
for m in pattern.finditer(text):
  t = (int(m.group(1)), int(m.group(2)), int(m.group(3)))
  if best is None or t > best:
    best = t
    best_str = m.group(0)

print(best_str)
PY
}

extract_upload_path_fallback() {
  # Best-effort extraction without a JSON parser.
  # Expected shape: {"upload_path":"https://..."}
  # Remove newlines to simplify matching.
  tr -d '\n' | sed -n 's/.*"upload_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

py_json_get_provider_default_arch_v2() {
  local provider="${1}"
  python3 - "${provider}" <<'PY'
import json
import sys

provider = sys.argv[1]
text = sys.stdin.read()

try:
  obj = json.loads(text) if text.strip() else {}
except Exception:
  print("")
  raise SystemExit(0)

providers = obj.get("providers") if isinstance(obj, dict) else None
if not isinstance(providers, list):
  print("")
  raise SystemExit(0)

matches = [p for p in providers if isinstance(p, dict) and p.get("name") == provider]
if not matches:
  print("")
  raise SystemExit(0)

# Prefer the default architecture entry, otherwise first match.
for p in matches:
  if p.get("default_architecture") is True and isinstance(p.get("architecture"), str):
    print(p.get("architecture"))
    raise SystemExit(0)

arch = matches[0].get("architecture")
print(arch if isinstance(arch, str) else "")
PY
}

determine_version() {
  local canonical_box="${1}"

  if [[ -n "${VERSION}" ]]; then
    printf '%s' "${VERSION}"
    return 0
  fi

  require_cmd vagrant

  local local_version
  local_version="$(get_local_latest_version "${NAMESPACE}/${canonical_box}" "${PROVIDER}" "${ARCH}")"
  if [[ -z "${local_version}" ]]; then
    die "No local version found for ${NAMESPACE}/${canonical_box} (${PROVIDER}/${ARCH}). Install it locally (e.g. via ./scripts/build.sh ${canonical_box}) or pass --version/VAGRANT_CLOUD_VERSION."
  fi

  printf '%s' "${local_version}"
}

ensure_box_exists() {
  local box="${1}"

  if [[ "${DRY_RUN}" == "1" ]]; then
    return 0
  fi

  vc_request GET "/api/v1/box/${NAMESPACE}/${box}"
  case "${VC_HTTP_CODE}" in
    200) return 0 ;;
    404) ;;
    *) die "Unexpected response checking box ${NAMESPACE}/${box}: HTTP ${VC_HTTP_CODE} body=${VC_BODY}" ;;
  esac

  local short_desc="Auto-built libvirt base box (${box})"
  local payload
  payload="$(cat <<JSON
{"box":{"username":"${NAMESPACE}","name":"${box}","is_private":false,"short_description":"${short_desc}"}}
JSON
)"

  vc_request POST "/api/v1/boxes" "${payload}"
  if [[ "${VC_HTTP_CODE}" != "200" && "${VC_HTTP_CODE}" != "201" ]]; then
    die "Failed creating box ${NAMESPACE}/${box}: HTTP ${VC_HTTP_CODE} body=${VC_BODY}"
  fi
}

ensure_version_exists() {
  local box="${1}"
  local version="${2}"

  if [[ "${DRY_RUN}" == "1" ]]; then
    return 0
  fi

  local payload
  payload="$(cat <<JSON
{"version":{"version":"${version}","description":"Automated build ${version}"}}
JSON
)"

  vc_request POST "/api/v1/box/${NAMESPACE}/${box}/versions" "${payload}"

  case "${VC_HTTP_CODE}" in
    200|201) return 0 ;;
    409|422) return 0 ;; # already exists / validation error for duplicate
    *) die "Failed creating version ${NAMESPACE}/${box} ${version}: HTTP ${VC_HTTP_CODE} body=${VC_BODY}" ;;
  esac
}

ensure_provider_exists() {
  local box="${1}"
  local version="${2}"
  local provider="${3}"
  local arch="${4}"
  local box_file="${5}"

  if [[ "${DRY_RUN}" == "1" ]]; then
    return 0
  fi

  local checksum
  checksum="$(sha256sum "${box_file}" | awk '{print $1}')"

  local payload
  payload="$(cat <<JSON
{"provider":{"name":"${provider}","checksum_type":"sha256","checksum":"${checksum}","architecture":"${arch}"}}
JSON
)"

  vc_request POST "/api/v1/box/${NAMESPACE}/${box}/version/${version}/providers" "${payload}"

  case "${VC_HTTP_CODE}" in
    200|201) return 0 ;;
    409|422) return 0 ;; # already exists / arch ignored / validation
    *) die "Failed creating provider ${NAMESPACE}/${box} ${version} ${provider}: HTTP ${VC_HTTP_CODE} body=${VC_BODY}" ;;
  esac
}

get_upload_path() {
  local box="${1}"
  local version="${2}"
  local provider="${3}"
  local arch="${4}"

  UPLOAD_PATH=""

  if [[ "${DRY_RUN}" == "1" ]]; then
    # Placeholder URL; upload is skipped in dry-run mode.
    UPLOAD_PATH="https://example.invalid/dry-run-upload"
    VC_HTTP_CODE="200"
    VC_BODY='{"upload_path":"https://example.invalid/dry-run-upload"}'
    return 0
  fi

  vc_request GET "/api/v2/box/${NAMESPACE}/${box}/version/${version}/provider/${provider}/${arch}/upload"

  if [[ "${VC_HTTP_CODE}" == "200" ]]; then
    UPLOAD_PATH="$(printf '%s' "${VC_BODY}" | py_json_get_field upload_path)"
    if [[ -z "${UPLOAD_PATH}" ]]; then
      UPLOAD_PATH="$(printf '%s' "${VC_BODY}" | extract_upload_path_fallback)"
    fi
    return 0
  fi
  return 0
}

get_latest_remote_version() {
  local box="${1}"

  LATEST_REMOTE_VERSION=""

  vc_request GET "/api/v1/box/${NAMESPACE}/${box}"
  if [[ "${VC_HTTP_CODE}" != "200" ]]; then
    return 0
  fi

  LATEST_REMOTE_VERSION="$(printf '%s' "${VC_BODY}" | py_json_get_latest_version_v1 || true)"
  if [[ -z "${LATEST_REMOTE_VERSION}" ]]; then
    LATEST_REMOTE_VERSION="$(printf '%s' "${VC_BODY}" | py_regex_latest_semver || true)"
  fi
  return 0
}

should_skip_upload() {
  local box="${1}"
  local version="${2}"
  local provider="${3}"
  local arch="${4}"
  local local_checksum="${5}"

  vc_request GET "/api/v2/box/${NAMESPACE}/${box}/version/${version}/provider/${provider}/${arch}"
  case "${VC_HTTP_CODE}" in
    200)
      local remote_checksum
      local remote_checksum_type
      remote_checksum="$(printf '%s' "${VC_BODY}" | py_json_get_field checksum)"
      remote_checksum_type="$(printf '%s' "${VC_BODY}" | py_json_get_field checksum_type)"

      if [[ -n "${remote_checksum}" && "${remote_checksum_type}" == "sha256" && "${remote_checksum}" == "${local_checksum}" ]]; then
        return 0
      fi

      # Provider exists but differs. Refuse to overwrite if the version is already released/active.
      vc_request GET "/api/v2/box/${NAMESPACE}/${box}/version/${version}"
      if [[ "${VC_HTTP_CODE}" == "200" ]]; then
        local st
        st="$(printf '%s' "${VC_BODY}" | py_json_get_field status)"
        if [[ "${st}" == "released" || "${st}" == "active" ]]; then
          die "Remote ${NAMESPACE}/${box} ${version} is already ${st} but local artifact differs. Bump the local box version first; publishing does not overwrite released versions."
        fi
      fi
      return 1
      ;;
    404) return 1 ;;
    401|403) die "Auth failed checking remote checksum for ${NAMESPACE}/${box} ${version} ${provider}/${arch}: HTTP ${VC_HTTP_CODE} body=${VC_BODY}" ;;
    *) return 1 ;;
  esac
}

verify_provider_uploaded() {
  local box="${1}"
  local version="${2}"
  local provider="${3}"
  local arch="${4}"

  if [[ "${DRY_RUN}" == "1" ]]; then
    return 0
  fi

  vc_request GET "/api/v2/box/${NAMESPACE}/${box}/version/${version}/provider/${provider}/${arch}"
  [[ "${VC_HTTP_CODE}" == "200" ]]
}

release_version() {
  local box="${1}"
  local version="${2}"

  if [[ "${DRY_RUN}" == "1" ]]; then
    return 0
  fi

  # Avoid calling release endpoint if already released (important for retries).
  vc_request GET "/api/v2/box/${NAMESPACE}/${box}/version/${version}"
  if [[ "${VC_HTTP_CODE}" == "200" ]]; then
    local st
    st="$(printf '%s' "${VC_BODY}" | py_json_get_field status)"
    if [[ "${st}" == "released" || "${st}" == "active" ]]; then
      return 0
    fi
  fi

  vc_request PUT "/api/v1/box/${NAMESPACE}/${box}/version/${version}/release"
  if [[ "${VC_HTTP_CODE}" == "200" || "${VC_HTTP_CODE}" == "204" ]]; then
    return 0
  fi

  # Some APIs return Method Not Allowed if the version is already released.
  if [[ "${VC_HTTP_CODE}" == "501" ]]; then
    vc_request GET "/api/v2/box/${NAMESPACE}/${box}/version/${version}"
    if [[ "${VC_HTTP_CODE}" == "200" ]]; then
      local st
      st="$(printf '%s' "${VC_BODY}" | py_json_get_field status)"
      if [[ "${st}" == "released" || "${st}" == "active" ]]; then
        return 0
      fi
    fi
  fi

  # Fallback if API expects POST.
  vc_request POST "/api/v1/box/${NAMESPACE}/${box}/version/${version}/release"
  if [[ "${VC_HTTP_CODE}" == "200" || "${VC_HTTP_CODE}" == "201" || "${VC_HTTP_CODE}" == "204" ]]; then
    return 0
  fi

  if [[ "${VC_HTTP_CODE}" == "501" ]]; then
    vc_request GET "/api/v2/box/${NAMESPACE}/${box}/version/${version}"
    if [[ "${VC_HTTP_CODE}" == "200" ]]; then
      local st
      st="$(printf '%s' "${VC_BODY}" | py_json_get_field status)"
      if [[ "${st}" == "released" || "${st}" == "active" ]]; then
        return 0
      fi
    fi
  fi

  die "Failed releasing ${NAMESPACE}/${box} ${version}: HTTP ${VC_HTTP_CODE} body=${VC_BODY}"
}

boxes=()

while [[ ${#@} -gt 0 ]]; do
  case "${1}" in
    --namespace)
      NAMESPACE="${2}"; shift 2 ;;
    --provider)
      PROVIDER="${2}"; shift 2 ;;
    --arch)
      ARCH="${2}"; shift 2 ;;
    --version)
      VERSION="${2}"; shift 2 ;;
    --build)
      DO_BUILD=1; shift ;;
    --no-build)
      DO_BUILD=0; shift ;;
    --rebuild)
      REBUILD=1; shift ;;
    --release)
      DO_RELEASE=1; shift ;;
    --no-release)
      DO_RELEASE=0; shift ;;
    --dry-run)
      DRY_RUN=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    --)
      shift; break ;;
    -*)
      die "Unknown option: ${1}" ;;
    *)
      boxes+=("${1}"); shift ;;
  esac
done

# Remaining positional args are boxes too
while [[ ${#@} -gt 0 ]]; do
  boxes+=("${1}"); shift
done

require_cmd curl
require_cmd python3
require_cmd sha256sum

if [[ "${DRY_RUN}" != "1" ]]; then
  resolve_token
fi

# Default architecture for our builds is amd64.
if [[ -z "${ARCH}" ]]; then
  ARCH="amd64"
fi

if [[ -z "${NAMESPACE}" ]]; then
  die "Missing namespace. Set VAGRANT_CLOUD_NAMESPACE or pass --namespace."
fi

if [[ ${#boxes[@]} -eq 0 ]]; then
  mapfile -t boxes < <(find packer/vars -maxdepth 1 -type f -name '*.pkrvars.hcl' -printf '%f\n' | sed 's/\.pkrvars\.hcl$//' | sort)
fi

[[ ${#boxes[@]} -gt 0 ]] || die "No boxes found"

if [[ -n "${VERSION}" ]]; then
  log "Publishing version (forced): ${VERSION}"
else
  log "Publishing versions: per-box (auto)"
fi
log "Namespace: ${NAMESPACE}"
log "Provider: ${PROVIDER}"
log "Arch:     ${ARCH}"

for box in "${boxes[@]}"; do
  box_file="output-${box}/package.box"

  log ""
  log "==> Box: ${box}"

  if [[ "${DO_BUILD}" == "1" ]]; then
    if [[ "${REBUILD}" == "1" || ! -f "${box_file}" ]]; then
      log "Building ${box}..."
      if [[ "${DRY_RUN}" == "1" ]]; then
        log "DRY-RUN: ./scripts/build.sh ${box}"
      else
        ./scripts/build.sh "${box}"
      fi
    else
      log "Build skipped (artifact exists): ${box_file}"
    fi
  fi

  [[ -f "${box_file}" || "${DRY_RUN}" == "1" ]] || die "Missing artifact: ${box_file}"

  # Long runs can exceed the HCP access token lifetime.
  if [[ "${DRY_RUN}" != "1" && "${TOKEN_SOURCE}" == "hcp" && "${HCP_ACCESS_TOKEN:-}" == "" ]]; then
    resolve_token
  fi

  ensure_box_exists "${box}"

  box_version="$(determine_version "${box}")"
  log "Publishing box version: ${box_version}"

  if [[ "${DRY_RUN}" != "1" ]]; then
    local_checksum="$(sha256sum "${box_file}" | awk '{print $1}')"
    if should_skip_upload "${box}" "${box_version}" "${PROVIDER}" "${ARCH}" "${local_checksum}"; then
      log "Skip: local artifact matches remote (${box_version})"
      continue
    fi
  fi

  ensure_version_exists "${box}" "${box_version}"

  # Ensure provider exists (best-effort; include architecture so UI shows correct arch).
  ensure_provider_exists "${box}" "${box_version}" "${PROVIDER}" "${ARCH}" "${box_file}"

  get_upload_path "${box}" "${box_version}" "${PROVIDER}" "${ARCH}"
  upload_path="${UPLOAD_PATH}"

  upload_http_code="${VC_HTTP_CODE}"
  upload_body="${VC_BODY}"

  if [[ -z "${upload_path}" ]]; then
    if [[ "${upload_http_code}" == "200" ]]; then
      log "upload_path parse failed: HTTP ${upload_http_code} body=${upload_body}"
    else
      log "upload_path request failed: HTTP ${upload_http_code} body=${upload_body}"
    fi

    # Do not silently fall back to "unknown"; if architecture is wrong, fail loudly.
    # (If you really need it, set VAGRANT_CLOUD_ARCH=unknown explicitly.)
  fi

  if [[ -z "${upload_path}" ]]; then
    die "Failed to get upload_path for ${NAMESPACE}/${box} ${box_version} ${PROVIDER}/${ARCH}: HTTP ${upload_http_code} body=${upload_body}"
  fi

  log "Uploading ${box_file}..."
  if [[ "${DRY_RUN}" == "1" ]]; then
    log "DRY-RUN: curl -X PUT --upload-file ${box_file} ${upload_path}"
  else
    curl -sS -L -X PUT --upload-file "${box_file}" "${upload_path}" >/dev/null
  fi

  log "Verifying upload..."
  if [[ "${DRY_RUN}" != "1" ]]; then
    if ! verify_provider_uploaded "${box}" "${box_version}" "${PROVIDER}" "${ARCH}"; then
      die "Upload verification failed for ${NAMESPACE}/${box} ${box_version} ${PROVIDER}/${ARCH}: HTTP ${VC_HTTP_CODE} body=${VC_BODY}"
    fi
  fi

  if [[ "${DO_RELEASE}" == "1" ]]; then
    log "Releasing version..."
    release_version "${box}" "${box_version}"
  else
    log "Release skipped (--no-release)"
  fi

done

log ""
log "Done."
