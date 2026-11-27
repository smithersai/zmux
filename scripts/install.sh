#!/bin/sh
# Verified release installer for smithersai/zmux.
# Downloads the matching prebuilt tarball and .sha256 sidecar from GitHub Releases,
# checks the SHA-256 digest before extracting, and installs zmuxd + zmux-connect.
set -eu

REPO="${ZMUX_REPO:-smithersai/zmux}"
INSTALL_DIR="${ZMUX_INSTALL_DIR:-$HOME/.local/bin}"
VERSION="${ZMUX_VERSION:-latest}"
DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --version=*) VERSION="${arg#--version=}" ;;
    --dir=*) INSTALL_DIR="${arg#--dir=}" ;;
    -h|--help)
      printf 'Usage: install.sh [--dry-run] [--version=v0.4.0] [--dir=~/.local/bin]\n'
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "$arg" >&2
      exit 2
      ;;
  esac
done

OS_RAW="${ZMUX_TEST_OS:-$(uname -s)}"
ARCH_RAW="${ZMUX_TEST_ARCH:-$(uname -m)}"

case "$OS_RAW" in
  Linux|linux) OS="linux" ;;
  Darwin|darwin) OS="macos" ;;
  *)
    printf 'Unsupported OS: %s (zmux provides linux and macos releases)\n' "$OS_RAW" >&2
    exit 1
    ;;
esac

case "$ARCH_RAW" in
  x86_64|amd64) ARCH="x64" ;;
  arm64|aarch64) ARCH="arm64" ;;
  *)
    printf 'Unsupported architecture: %s (zmux provides arm64 and x64 releases)\n' "$ARCH_RAW" >&2
    exit 1
    ;;
esac

TARGET="${OS}-${ARCH}"

if [ "$VERSION" = "latest" ] && [ "$DRY_RUN" -eq 0 ]; then
  TAG="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
  if [ -z "$TAG" ]; then
    printf 'Failed to resolve latest release tag for %s\n' "$REPO" >&2
    exit 1
  fi
else
  TAG="$VERSION"
fi

ARCHIVE="zmux-${TAG}-${TARGET}.tar.gz"
if [ "$TAG" = "latest" ]; then
  BASE_URL="https://github.com/${REPO}/releases/latest/download"
else
  BASE_URL="https://github.com/${REPO}/releases/download/${TAG}"
fi
TARBALL_URL="${BASE_URL}/${ARCHIVE}"
SHA_URL="${TARBALL_URL}.sha256"

if [ "$DRY_RUN" -eq 1 ]; then
  printf 'repo=%s\ntag=%s\ntarget=%s\narchive=%s\ntarball_url=%s\nsha256_url=%s\ninstall_dir=%s\n' \
    "$REPO" "$TAG" "$TARGET" "$ARCHIVE" "$TARBALL_URL" "$SHA_URL" "$INSTALL_DIR"
  exit 0
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

printf 'Downloading %s\n' "$TARBALL_URL"
curl -fsSL "$TARBALL_URL" -o "${TMP_DIR}/${ARCHIVE}"
curl -fsSL "$SHA_URL" -o "${TMP_DIR}/${ARCHIVE}.sha256"

EXPECTED_SHA="$(awk '{print $1}' "${TMP_DIR}/${ARCHIVE}.sha256" | head -n 1)"
if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL_SHA="$(sha256sum "${TMP_DIR}/${ARCHIVE}" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL_SHA="$(shasum -a 256 "${TMP_DIR}/${ARCHIVE}" | awk '{print $1}')"
else
  printf 'Neither sha256sum nor shasum found to verify archive integrity\n' >&2
  exit 1
fi

if [ -z "$EXPECTED_SHA" ] || [ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]; then
  printf 'SHA-256 checksum mismatch for %s (expected %s, got %s)\n' "$ARCHIVE" "$EXPECTED_SHA" "$ACTUAL_SHA" >&2
  exit 1
fi

mkdir -p "$INSTALL_DIR"
tar -xzf "${TMP_DIR}/${ARCHIVE}" -C "$TMP_DIR"
install -m 0755 "${TMP_DIR}/zmuxd" "${INSTALL_DIR}/zmuxd"
install -m 0755 "${TMP_DIR}/zmux-connect" "${INSTALL_DIR}/zmux-connect"

printf 'Installed zmuxd and zmux-connect (%s, verified SHA-256 %s) to %s\n' "$TAG" "$ACTUAL_SHA" "$INSTALL_DIR"
