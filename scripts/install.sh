#!/bin/sh
set -eu

# Audited POSIX installer for zmux (zmux, zmuxd, zmux-connect).
# Requires SHA-256 verification before extracting or touching the install directory.

REPO="${ZMUX_REPO:-smithersai/zmux}"
VERSION="${ZMUX_VERSION:-}"
INSTALL_DIR="${ZMUX_INSTALL_DIR:-${HOME:-/tmp}/.local/bin}"
BASE_URL="${ZMUX_BASE_URL:-}"
DRY_RUN=0
TMP_DIR=""
STAGED_FILE=""

usage() {
    cat <<'EOF'
Usage: install.sh [OPTIONS]

Install prebuilt zmux binaries (zmux, zmuxd, zmux-connect) with mandatory SHA-256 verification.

Options:
  --version vX.Y.Z   Release tag to install (default: latest GitHub release)
  --dir DIR          Target directory (default: $ZMUX_INSTALL_DIR or ~/.local/bin)
  --base-url URL     Base URL for release assets and SHA256SUMS (supports file://)
  --repo OWNER/REPO  GitHub repository (default: smithersai/zmux)
  --dry-run          Print detected target and planned actions without modifying files
  -h, --help         Show this help message
EOF
}

say() {
    printf '%s\n' "$*"
}

err() {
    printf 'zmux-install: error: %s\n' "$*" >&2
}

die() {
    err "$*"
    exit 1
}

cleanup() {
    if [ -n "$STAGED_FILE" ] && [ -e "$STAGED_FILE" ]; then
        rm -f "$STAGED_FILE" || true
    fi
    if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR" || true
    fi
}

trap cleanup EXIT INT TERM

need_cmd() {
    command -v "$1" >/dev/null 2>&1
}

detect_os() {
    raw_os="${ZMUX_OS:-${ZMUX_TEST_OS:-$(uname -s)}}"
    case "$raw_os" in
        Linux|linux)
            printf '%s\n' "linux"
            ;;
        Darwin|darwin)
            printf '%s\n' "darwin"
            ;;
        *)
            die "Unsupported OS: ${raw_os} (zmux provides linux and macos releases)"
            ;;
    esac
}

detect_arch() {
    raw_arch="${ZMUX_ARCH:-${ZMUX_TEST_ARCH:-$(uname -m)}}"
    case "$raw_arch" in
        x86_64|amd64)
            printf '%s\n' "x64"
            ;;
        arm64|aarch64)
            printf '%s\n' "arm64"
            ;;
        *)
            die "Unsupported architecture: ${raw_arch} (supported: x86_64, amd64, arm64, aarch64)"
            ;;
    esac
}

resolve_target() {
    os_name="$1"
    arch_name="$2"
    case "$os_name" in
        darwin)
            printf 'macos-%s\n' "$arch_name"
            ;;
        linux)
            printf 'linux-%s\n' "$arch_name"
            ;;
        *)
            die "unsupported target platform: ${os_name}-${arch_name}"
            ;;
    esac
}

normalize_version() {
    v="$1"
    case "$v" in
        ""|latest)
            printf '%s\n' "latest"
            ;;
        v*)
            printf '%s\n' "$v"
            ;;
        *)
            printf 'v%s\n' "$v"
            ;;
    esac
}

download_file() {
    url="$1"
    dest="$2"
    case "$url" in
        file://*)
            src_path="${url#file://}"
            if [ ! -f "$src_path" ]; then
                return 1
            fi
            cp "$src_path" "$dest"
            return 0
            ;;
    esac

    if need_cmd curl; then
        curl -fsSL --proto '=https' --tlsv1.2 -o "$dest" "$url"
        return $?
    fi
    if need_cmd wget; then
        wget -q -O "$dest" "$url"
        return $?
    fi
    die "neither curl nor wget is available to download ${url}"
}

download_text() {
    url="$1"
    case "$url" in
        file://*)
            src_path="${url#file://}"
            if [ ! -f "$src_path" ]; then
                return 1
            fi
            cat "$src_path"
            return 0
            ;;
    esac

    if need_cmd curl; then
        curl -fsSL --proto '=https' --tlsv1.2 "$url"
        return $?
    fi
    if need_cmd wget; then
        wget -qO- "$url"
        return $?
    fi
    die "neither curl nor wget is available to fetch ${url}"
}

resolve_latest_version() {
    api_url="https://api.github.com/repos/${REPO}/releases/latest"
    body="$(download_text "$api_url")" || die "failed to query latest release from ${api_url}"
    tag="$(printf '%s\n' "$body" | sed -nE 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -n 1)"
    if [ -z "$tag" ]; then
        die "could not determine latest release tag from ${api_url}"
    fi
    normalize_version "$tag"
}

compute_sha256() {
    file_path="$1"
    if need_cmd sha256sum; then
        sha256sum "$file_path" | awk '{print tolower($1)}'
        return 0
    fi
    if need_cmd shasum; then
        shasum -a 256 "$file_path" | awk '{print tolower($1)}'
        return 0
    fi
    die "SHA-256 verification requires sha256sum or shasum"
}

is_valid_sha256() {
    hash_val="$1"
    printf '%s\n' "$hash_val" | grep -Eq '^[0-9a-fA-F]{64}$'
}

lookup_checksum() {
    sums_file="$1"
    asset_name="$2"
    awk -v target="$asset_name" '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        {
            hash = tolower($1)
            name = $2
            sub(/^\*/, "", name)
            sub(/^\.\//, "", name)
            n = split(name, parts, "/")
            base = parts[n]
            if (name == target || base == target) {
                print hash
                exit 0
            }
        }
    ' "$sums_file"
}

verify_checksum() {
    archive_path="$1"
    expected_hash="$2"
    asset_name="$3"

    if ! is_valid_sha256 "$expected_hash"; then
        die "invalid SHA-256 digest for ${asset_name}: ${expected_hash}"
    fi
    actual_hash="$(compute_sha256 "$archive_path")"
    expected_lower="$(printf '%s\n' "$expected_hash" | tr '[:upper:]' '[:lower:]')"
    if [ "$actual_hash" != "$expected_lower" ]; then
        die "SHA-256 checksum mismatch for ${asset_name} (expected ${expected_lower}, got ${actual_hash})"
    fi
}

install_binary_atomic() {
    src_bin="$1"
    dest_dir="$2"
    bin_name="$3"

    STAGED_FILE="$(mktemp "${dest_dir}/.${bin_name}.install.XXXXXX")"
    cp "$src_bin" "$STAGED_FILE"
    chmod 0755 "$STAGED_FILE"
    mv -f "$STAGED_FILE" "${dest_dir}/${bin_name}"
    STAGED_FILE=""
}

in_path() {
    needle="$1"
    case ":${PATH:-}:" in
        *":${needle}:"*) return 0 ;;
        *) return 1 ;;
    esac
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --version)
                [ "$#" -ge 2 ] || { err "--version requires a value"; exit 2; }
                VERSION="$2"
                shift 2
                ;;
            --version=*)
                VERSION="${1#--version=}"
                shift
                ;;
            --dir)
                [ "$#" -ge 2 ] || { err "--dir requires a value"; exit 2; }
                INSTALL_DIR="$2"
                shift 2
                ;;
            --dir=*)
                INSTALL_DIR="${1#--dir=}"
                shift
                ;;
            --base-url)
                [ "$#" -ge 2 ] || { err "--base-url requires a value"; exit 2; }
                BASE_URL="$2"
                shift 2
                ;;
            --base-url=*)
                BASE_URL="${1#--base-url=}"
                shift
                ;;
            --repo)
                [ "$#" -ge 2 ] || { err "--repo requires a value"; exit 2; }
                REPO="$2"
                shift 2
                ;;
            --repo=*)
                REPO="${1#--repo=}"
                shift
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                err "unknown argument: $1"
                usage >&2
                exit 2
                ;;
        esac
    done
}

main() {
    parse_args "$@"

    if [ -z "$INSTALL_DIR" ]; then
        die "install directory must not be empty"
    fi

    os_name="$(detect_os)"
    arch_name="$(detect_arch)"
    target="$(resolve_target "$os_name" "$arch_name")"
    norm_version="$(normalize_version "$VERSION")"

    if [ -n "$BASE_URL" ]; then
        resolved_base_url="${BASE_URL%/}"
        resolved_version="$norm_version"
    else
        if [ "$norm_version" = "latest" ] && [ "$DRY_RUN" -eq 1 ]; then
            resolved_version="latest"
            resolved_base_url="https://github.com/${REPO}/releases/latest/download"
        else
            if [ "$norm_version" = "latest" ]; then
                resolved_version="$(resolve_latest_version)"
            else
                resolved_version="$norm_version"
            fi
            resolved_base_url="https://github.com/${REPO}/releases/download/${resolved_version}"
        fi
    fi

    versioned_archive="zmux-${resolved_version}-${target}.tar.gz"
    versioned_url="${resolved_base_url}/${versioned_archive}"

    if [ "$DRY_RUN" -eq 1 ]; then
        say "zmux installer dry run"
        say "  os:          ${os_name}"
        say "  arch:        ${arch_name}"
        say "  target:      ${target}"
        say "  version:     ${resolved_version}"
        say "  base_url:    ${resolved_base_url}"
        say "  checksums:   ${resolved_base_url}/SHA256SUMS"
        say "  archive:     ${resolved_base_url}/zmux-${target}.tar.gz"
        say "  install_dir: ${INSTALL_DIR}"
        say "  binaries:    zmux zmuxd zmux-connect"
        say "repo=${REPO}"
        say "tag=${resolved_version}"
        say "target=${target}"
        say "archive=${versioned_archive}"
        say "tarball_url=${versioned_url}"
        say "sha256_url=${versioned_url}.sha256"
        say "install_dir=${INSTALL_DIR}"
        exit 0
    fi

    need_cmd tar || die "tar is required to extract release archives"
    if ! need_cmd sha256sum && ! need_cmd shasum; then
        die "SHA-256 verification requires sha256sum or shasum"
    fi

    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/zmux-install.XXXXXX")"
    sums_file="${TMP_DIR}/SHA256SUMS"
    extract_dir="${TMP_DIR}/extract"
    mkdir -p "$extract_dir"

    if ! download_file "${resolved_base_url}/SHA256SUMS" "$sums_file"; then
        die "failed to fetch mandatory SHA256SUMS from ${resolved_base_url}/SHA256SUMS"
    fi

    archives=""
    for unified_asset in "$versioned_archive" "zmux-${target}.tar.gz"; do
        unified_hash="$(lookup_checksum "$sums_file" "$unified_asset")"
        if [ -n "$unified_hash" ]; then
            archives="$unified_asset"
            break
        fi
    done

    for split_asset in "zmuxd-${target}.tar.gz" "zmux-connect-${target}.tar.gz"; do
        split_hash="$(lookup_checksum "$sums_file" "$split_asset")"
        if [ -n "$split_hash" ]; then
            if [ -z "$archives" ]; then
                archives="$split_asset"
            else
                archives="${archives} ${split_asset}"
            fi
        fi
    done

    if [ -z "$archives" ]; then
        die "no release archive for target '${target}' found in SHA256SUMS"
    fi

    for asset in $archives; do
        expected="$(lookup_checksum "$sums_file" "$asset")"
        if [ -z "$expected" ]; then
            die "missing SHA-256 checksum for ${asset} in SHA256SUMS"
        fi
        archive_path="${TMP_DIR}/${asset}"
        download_file "${resolved_base_url}/${asset}" "$archive_path" || die "failed to download ${resolved_base_url}/${asset}"
        verify_checksum "$archive_path" "$expected" "$asset"
        tar -xzf "$archive_path" -C "$extract_dir"
    done

    found_bins=""
    for bin_name in zmux zmuxd zmux-connect; do
        if [ -f "${extract_dir}/${bin_name}" ]; then
            if [ -z "$found_bins" ]; then
                found_bins="$bin_name"
            else
                found_bins="${found_bins} ${bin_name}"
            fi
        fi
    done

    if [ -z "$found_bins" ]; then
        die "verified archive(s) contained none of zmux, zmuxd, or zmux-connect"
    fi

    mkdir -p "$INSTALL_DIR"
    for bin_name in $found_bins; do
        install_binary_atomic "${extract_dir}/${bin_name}" "$INSTALL_DIR" "$bin_name"
    done

    say "Installed ${found_bins} to ${INSTALL_DIR} (target: ${target}, version: ${resolved_version})"
    if ! in_path "$INSTALL_DIR"; then
        say ""
        say "Add ${INSTALL_DIR} to your PATH to run zmux directly:"
        say "  export PATH=\"${INSTALL_DIR}:\$PATH\""
    fi
}

main "$@"
