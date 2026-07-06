#!/usr/bin/env bash
# =============================================================================
# download_update.sh — Fetch the latest Arkham Horror LCG release archive.
#
# Step 0 of the upgrade flow:
#   discover latest version -> compare -> probe network -> pick strategy ->
#   download archive to BASE_DIR.
#
# Flow:
#   1. Call resolve_best_latest_tag() to resolve the latest release tag
#      across candidate repos (5s timeout each).
#   2. If a latest tag is available and not newer than the local version,
#      report and exit; otherwise continue.
#   3. Probe generate_204 (3s timeout) to decide direct vs. proxied fetch:
#      - reachable + tag known -> direct GitHub releases download
#      - reachable + tag unknown -> resolve again, then direct download
#      - unreachable + tag known -> gh-proxy + known tag download
#      - unreachable + tag unknown -> gh-proxy + date-descending probe
#        (up to 30 tries)
#   4. Skip download if the target file already exists locally.
# =============================================================================
set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; CYAN='\033[36m'; RESET='\033[0m'
die()  { printf "${RED}[error]${RESET} %s\n" "$*" >&2; exit 1; }
info() { printf "${CYAN}[info]${RESET} %s\n" "$*"; }
warn() { printf "${YELLOW}[warn]${RESET} %s\n" "$*" >&2; }
ok()   { printf "${GREEN}[ok]${RESET} %s\n" "$*"; }

# ── Interrupt cleanup ─────────────────────────────────────────────────────────
# Clean up any leftover .partial file if the script is interrupted.
cleanup_partial() {
    [ -n "${DEST_PATH:-}" ] && rm -f "${DEST_PATH}.partial"
}
trap cleanup_partial INT TERM

# ── Resolve BASE_DIR ──────────────────────────────────────────────────────────
if [ $# -ge 1 ] && [ -n "$1" ]; then
    BASE_DIR="$1"
else
    BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
fi

GAME_DIR="${BASE_DIR}/game"

if [ ! -d "$GAME_DIR" ]; then
    die "game/ directory not found: ${GAME_DIR}"
fi

BASE_REPO_URL="https://github.com/haolloyin/ArkhamHorror-offline/"
UPSTREAM_REPO_URL="https://github.com/halogenandtoast/ArkhamHorror/"
GH_PROXY_URL="https://gh-proxy.org/"

# Candidate repos: query both when resolving the latest tag; pick the newer one.
# Ties favor haolloyin/ArkhamHorror-offline (only the fork ships the offline
# archive naming). If both queries fail, BASE_REPO_URL keeps its default (fork)
# so scenario D's date-descending probe behaves as before.
CANDIDATE_REPO_URLS=(
    "https://github.com/haolloyin/ArkhamHorror-offline/"
    "https://github.com/halogenandtoast/ArkhamHorror/"
)

# ── 1. Detect platform ────────────────────────────────────────────────────────
UNAME_S="$(uname -s)"
case "$UNAME_S" in
    Linux*)   PLATFORM_KEY="linux-x86_64" ;;
    Darwin*)  PLATFORM_KEY="macos-arm64"  ;;
    *)        die "Unsupported platform: ${UNAME_S} (Linux or macOS required)" ;;
esac
info "Platform: ${PLATFORM_KEY}"

# ── 2. Utilities ──────────────────────────────────────────────────────────────

# Resolve the redirect target of releases/latest and print the final URL.
# Args: $1 — timeout seconds (default 5)
#       $2 — repository URL (default BASE_REPO_URL)
resolve_latest_url() {
    local timeout="${1:-5}"
    local repo_url="${2:-$BASE_REPO_URL}"
    local url="${repo_url}releases/latest"
    curl -fsSLI --connect-timeout "$timeout" --max-time "$timeout" \
        -o /dev/null -w '%{url_effective}' "$url"
}

# Iterate CANDIDATE_REPO_URLS and pick the repo with the highest release tag.
# Args: $1 — per-repo timeout seconds (default 5)
# Side effect: on success, updates the global BASE_REPO_URL to point at the
#              winning repo and prints the winning tag to stdout.
# Returns non-zero (empty stdout) when no repo yields a tag.
#
# Note: stdout is captured by the caller via $(), so all logs MUST go to
# stderr (>&2). Otherwise log text would be spliced into the tag and every
# downstream URL constructed from it would be invalid.
resolve_best_latest_tag() {
    local timeout="${1:-5}"
    local best_tag="" best_idx=-1 idx=0 repo resolved tag
    local total="${#CANDIDATE_REPO_URLS[@]}"
    for repo in "${CANDIDATE_REPO_URLS[@]}"; do
        idx=$((idx + 1))
        resolved="$(resolve_latest_url "$timeout" "$repo" || true)"
        if [ -z "$resolved" ]; then
            info "Candidate repo ${idx}/${total}: resolve failed" >&2
            continue
        fi
        tag="$(extract_tag_from_url "$resolved" || true)"
        if [ -z "$tag" ]; then
            info "Candidate repo ${idx}/${total}: could not extract tag" >&2
            continue
        fi
        info "Candidate repo ${idx}/${total}: tag ${tag}" >&2
        # Adopt the current repo when best_tag is empty or the new tag is
        # newer; ties keep the earlier repo (BASE takes precedence).
        if [ -z "$best_tag" ] || is_newer_version "$tag" "$best_tag"; then
            best_tag="$tag"
            best_idx="$idx"
            BASE_REPO_URL="$repo"
        fi
    done
    if [ -n "$best_tag" ]; then
        info "Selected candidate repo ${best_idx} (tag ${best_tag})" >&2
        printf '%s' "$best_tag"
        return 0
    fi
    return 1
}

# Extract the release tag from a resolved URL.
# Expected format: .../releases/tag/v<YYYYMMDD>.<N>
# N starts at 1 and grows (multiple releases in one day become v...\.1 /
# v...\.2 / v...\.3 …). The regex uses [0-9]+ for any digit count, so the
# suffix is not hard-coded to .1.
extract_tag_from_url() {
    local resolved_url="$1"
    printf '%s' "$resolved_url" \
        | sed -nE 's#.*/releases/tag/(v[0-9]+\.[0-9]+).*#\1#p'
}

# Read the local current-version marker.
read_local_version() {
    local ver=""
    for marker in "${GAME_DIR}"/current_v[0-9]*; do
        [ -e "$marker" ] || continue
        local fname
        fname="$(basename "$marker")"
        ver="${fname#current_}"
        break
    done
    printf '%s' "$ver"
}

# Compare two version strings (strip leading v, then string compare).
# Args: $1 — remote tag, $2 — local tag
# Returns: 0 when $1 > $2 (update available); 1 when $1 <= $2 (no update).
is_newer_version() {
    local remote="$1" local="$2"
    local remote_cmp="${remote#v}"
    local local_cmp="${local#v}"

    if [ "$local" = "$remote" ]; then
        return 1  # same version
    fi
    if [ "$local_cmp" \> "$remote_cmp" ]; then
        return 1  # local is newer
    fi
    return 0  # remote is newer
}

# Build every path/URL needed to download for a given tag.
# Sets globals: ARCHIVE_NAME, DOWNLOAD_URL, DEST_PATH
build_archive_info() {
    local tag="$1" prefix="${2:-}"
    ARCHIVE_NAME="ArkhamHorror-${PLATFORM_KEY}-${tag}.tar.gz"
    SHOW_URL="releases/download/${tag}/${ARCHIVE_NAME}"
    DOWNLOAD_URL="${prefix}${BASE_REPO_URL}${SHOW_URL}"
    DEST_PATH="${BASE_DIR}/${ARCHIVE_NAME}"
}

# Whether the target archive already exists and is non-empty.
archive_exists() {
    [ -s "$DEST_PATH" ]
}

# Probe URL reachability with a 1-byte range GET (some CDNs/proxies do not
# forward HEAD).
# Args: $1 — URL, $2 — timeout seconds (default 5)
url_reachable() {
    local url="$1" timeout="${2:-5}"
    curl -fsS -r 0-0 --connect-timeout "$timeout" --max-time "$timeout" \
        -o /dev/null "$url" >/dev/null 2>&1
}

# Atomic download: write to a .partial temp file, rename on success.
# Args: $1 — download URL, $2 — destination path
do_download() {
    local url="$1" dest="$2"
    local partial="${dest}.partial"

    rm -f "$partial"

    if ! curl -fL --retry 3 --retry-delay 2 -o "$partial" "$url"; then
        rm -f "$partial"
        return 1
    fi

    if [ ! -s "$partial" ]; then
        rm -f "$partial"
        return 1
    fi

    mv "$partial" "$dest"
    return 0
}

# Whether generate_204 is reachable within the given timeout.
# Args: $1 — timeout seconds (default 3)
check_network_204() {
    local timeout="${1:-3}"
    local http_code
    http_code="$(curl -fsS --connect-timeout "$timeout" --max-time "$timeout" \
        -o /dev/null -w '%{http_code}' \
        'http://www.gstatic.com/generate_204' 2>/dev/null || true)"
    [ "$http_code" = "204" ]
}

# Compute a date N days before today (portable across GNU date and BSD date).
# Args: $1 — days to subtract
offset_date() {
    local offset="$1" today result
    today="$(date +%Y%m%d)"

    # Try GNU date first
    result="$(date -d "${today} - ${offset} days" +%Y%m%d 2>/dev/null || true)"
    if [ -n "$result" ]; then
        printf '%s' "$result"
        return 0
    fi

    # Fall back to BSD date (macOS)
    result="$(date -v-${offset}d +%Y%m%d 2>/dev/null || true)"
    if [ -n "$result" ]; then
        printf '%s' "$result"
        return 0
    fi

    die "Unable to compute target date: date command not supported."
}

# Print the download plan (call after build_archive_info).
# Args: $1 — action label (e.g. "Downloading" / "Downloading via proxy")
print_download_plan() {
    local action="$1"
    info "Archive:     ${ARCHIVE_NAME}"
    info "URL path:    ${SHOW_URL}"
    info "Destination: ${DEST_PATH}"
    echo ""
    info "${action} ..."
}

# ── 3. Version + local file check helper ──────────────────────────────────────
# Given a tag, check: is it newer than local -> is the archive already local?
# Args: $1 — tag, $2 — URL prefix (optional, empty by default)
# Returns: 0 — needs download; 1 — not newer than local; 2 — archive exists locally
verify_download_needed() {
    local tag="$1" prefix="${2:-}"

    if [ -n "$CURRENT_VERSION" ] && ! is_newer_version "$tag" "$CURRENT_VERSION"; then
        return 1
    fi

    build_archive_info "$tag" "$prefix"

    if archive_exists; then
        return 2
    fi

    return 0
}

# ── 4. Main flow ──────────────────────────────────────────────────────────────

# 4a. Read local version
CURRENT_VERSION="$(read_local_version)"
if [ -n "$CURRENT_VERSION" ]; then
    info "Local version: ${CURRENT_VERSION}"
else
    info "Local version: (none — treated as pre-earliest)"
fi

# 4b. Step 1: try to resolve the latest tag (5s timeout per candidate repo)
info "Resolving latest release tag (5s timeout per candidate repo) ..."
LATEST_TAG="$(resolve_best_latest_tag 5 || true)"

# 4c. Step 2: version compare + local file check
if [ -n "$LATEST_TAG" ]; then
    info "Latest release tag: ${LATEST_TAG}"
    VERIFY_RC=0
    verify_download_needed "$LATEST_TAG" || VERIFY_RC=$?
    case "$VERIFY_RC" in
        1) ok "Local is already at the latest version ${CURRENT_VERSION}; no download needed."; echo ""; exit 0 ;;
        2) ok "Latest archive already present locally: ${ARCHIVE_NAME}; skipping download."; echo ""; exit 0 ;;
    esac
    ok "Need to download new version ${LATEST_TAG}."
else
    warn "Could not resolve the latest release tag (network may be down); continuing with fallbacks."
fi

# 4d. Step 3: probe generate_204 (3s timeout)
info "Probing network reachability (generate_204, 3s timeout) ..."
IS_DIRECT_NETWORK=false
if check_network_204 3; then
    IS_DIRECT_NETWORK=true
    ok "GitHub is directly reachable; using direct download mode"
else
    warn "GitHub is not directly reachable; will try proxied download mode"
fi
echo ""

# ── 5. Four-strategy download ─────────────────────────────────────────────────

# Case A: direct network + tag known -> direct GitHub download
#         (4c already checked version + local file, download straight away)
if [ "$IS_DIRECT_NETWORK" = true ] && [ -n "$LATEST_TAG" ]; then
    print_download_plan "Downloading"

    if ! do_download "$DOWNLOAD_URL" "$DEST_PATH"; then
        die "Download failed: ${DOWNLOAD_URL}"
    fi

# Case B: direct network + tag unknown -> resolve again, then direct download
elif [ "$IS_DIRECT_NETWORK" = true ] && [ -z "$LATEST_TAG" ]; then
    info "Resolving latest release tag again (10s timeout per candidate repo) ..."
    LATEST_TAG="$(resolve_best_latest_tag 10 || true)"
    if [ -z "$LATEST_TAG" ]; then
        die "Failed to resolve latest release tag; check the network."
    fi

    info "Latest release tag: ${LATEST_TAG}"
    VERIFY_RC=0
    verify_download_needed "$LATEST_TAG" || VERIFY_RC=$?
    case "$VERIFY_RC" in
        1) ok "Already at the latest version (${CURRENT_VERSION}); no download needed."; echo ""; exit 0 ;;
        2) ok "Latest archive already present locally: ${ARCHIVE_NAME}; skipping download."; echo ""; exit 0 ;;
    esac

    print_download_plan "Downloading"

    if ! do_download "$DOWNLOAD_URL" "$DEST_PATH"; then
        die "Download failed: ${DOWNLOAD_URL}"
    fi

# Case C: unreachable + tag known -> gh-proxy download
#         (4c already checked version + local file, download straight away)
elif [ "$IS_DIRECT_NETWORK" = false ] && [ -n "$LATEST_TAG" ]; then
    build_archive_info "$LATEST_TAG" "$GH_PROXY_URL"

    print_download_plan "Downloading via proxy"

    if ! do_download "$DOWNLOAD_URL" "$DEST_PATH"; then
        die "Proxy download failed: ${DOWNLOAD_URL}"
    fi

# Case D: unreachable + tag unknown -> gh-proxy + date-descending probe (up to 30 tries)
else
    MAX_RETRIES=30
    TRIES=0
    LATEST_TAG=""

    info "Probing by descending date for a new version (up to ${MAX_RETRIES} tries; may take 1-2 minutes) ..."

    while [ "$TRIES" -lt "$MAX_RETRIES" ]; do
        TARGET_DATE="$(offset_date "$TRIES")"
        TAG="v${TARGET_DATE}.1"

        build_archive_info "$TAG" "$GH_PROXY_URL"

        # Candidate is not newer than local -> we've walked back to (or before)
        # the local version; no newer version can exist further back.
        if [ -n "$CURRENT_VERSION" ] && ! is_newer_version "$TAG" "$CURRENT_VERSION"; then
            LATEST_TAG="$CURRENT_VERSION"
            break
        fi

        # Archive for this tag already exists locally -> skip download.
        if archive_exists; then
            LATEST_TAG="$TAG"
            warn "Cannot reach the server; a local archive for version ${TAG} already exists"
            break
        fi

        # Probe reachability with a range GET.
        if ! url_reachable "$DOWNLOAD_URL" 5; then
            TRIES=$((TRIES + 1))
            continue
        fi

        # Reachable — download.
        info "Found reachable version: ${TAG}; starting download ..."
        if do_download "$DOWNLOAD_URL" "$DEST_PATH"; then
            LATEST_TAG="$TAG"
            break
        fi

        TRIES=$((TRIES + 1))
    done

    if [ -z "$LATEST_TAG" ]; then
        die "No downloadable version found after ${MAX_RETRIES} tries."
    fi
fi

# ── 6. Final message ──────────────────────────────────────────────────────────
echo ""
if [ -n "$CURRENT_VERSION" ] && [ -n "$LATEST_TAG" ] && \
   ! is_newer_version "$LATEST_TAG" "$CURRENT_VERSION"; then
    ok "Already at the latest version (${CURRENT_VERSION}); no update needed."
else
    ok "Downloaded ${LATEST_TAG}"
fi
echo ""
