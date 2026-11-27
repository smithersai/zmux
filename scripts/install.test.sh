#!/bin/sh
set -eu

# Test suite for scripts/install.sh covering dry-run, OS/arch detection,
# offline verified installation, split-archive installation, and corrupted
# checksum rejection.

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
INSTALL_SH="${SCRIPT_DIR}/install.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/zmux-install-test.XXXXXX")"
cleanup() {
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT INT TERM

PASS_COUNT=0

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf 'PASS: %s\n' "$*"
}

assert_contains() {
    haystack="$1"
    needle="$2"
    label="$3"
    case "$haystack" in
        *"$needle"*) ;;
        *) fail "${label}: expected output to contain '${needle}', got: ${haystack}" ;;
    esac
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

detect_host_target() {
    raw_os="$(uname -s)"
    raw_arch="$(uname -m)"
    case "$raw_os" in
        Linux) os="linux" ;;
        Darwin) os="macos" ;;
        *) fail "unsupported test host OS: $raw_os" ;;
    esac
    case "$raw_arch" in
        x86_64|amd64) arch="x64" ;;
        arm64|aarch64) arch="arm64" ;;
        *) fail "unsupported test host arch: $raw_arch" ;;
    esac
    printf '%s-%s\n' "$os" "$arch"
}

HOST_TARGET="$(detect_host_target)"

# 1. Syntax check under sh (and dash if installed)
sh -n "$INSTALL_SH" || fail "sh -n syntax check failed"
if command -v dash >/dev/null 2>&1; then
    dash -n "$INSTALL_SH" || fail "dash -n syntax check failed"
fi
pass "POSIX shell syntax check"

# 2. --dry-run does not modify filesystem and reports target/URL/dir
dry_dir="${TMP_ROOT}/dry-target"
dry_out="$(sh "$INSTALL_SH" --dry-run --version v0.5.0 --dir "$dry_dir")"
assert_contains "$dry_out" "target:      ${HOST_TARGET}" "dry-run target"
assert_contains "$dry_out" "version:     v0.5.0" "dry-run version"
assert_contains "$dry_out" "install_dir: ${dry_dir}" "dry-run dir"
assert_contains "$dry_out" "zmux-${HOST_TARGET}.tar.gz" "dry-run archive"
[ ! -e "$dry_dir" ] || fail "dry-run must not create install directory"
pass "dry-run reports plan without side effects"

# 3. Cross-platform OS/arch detection matrix
for pair in \
    "Linux:x86_64:linux-x64" \
    "Linux:amd64:linux-x64" \
    "Linux:aarch64:linux-arm64" \
    "Linux:arm64:linux-arm64" \
    "Darwin:arm64:macos-arm64" \
    "Darwin:x86_64:macos-x64"; do
    os_val="$(printf '%s' "$pair" | cut -d: -f1)"
    arch_val="$(printf '%s' "$pair" | cut -d: -f2)"
    want_target="$(printf '%s' "$pair" | cut -d: -f3)"
    out="$(ZMUX_OS="$os_val" ZMUX_ARCH="$arch_val" sh "$INSTALL_SH" --dry-run --version 0.5.0)"
    assert_contains "$out" "target:      ${want_target}" "matrix ${pair}"
done

if ZMUX_OS="FreeBSD" ZMUX_ARCH="x86_64" sh "$INSTALL_SH" --dry-run >/dev/null 2>&1; then
    fail "expected unsupported OS to fail"
fi
if ZMUX_OS="Linux" ZMUX_ARCH="mips64" sh "$INSTALL_SH" --dry-run >/dev/null 2>&1; then
    fail "expected unsupported arch to fail"
fi
pass "OS and architecture detection matrix"

# 4. Offline unified tarball + valid SHA256SUMS installs zmux, zmuxd, zmux-connect atomically
fixture_dir="${TMP_ROOT}/release-unified"
stage_dir="${TMP_ROOT}/stage-unified"
install_dir="${TMP_ROOT}/bin-unified"
mkdir -p "$fixture_dir" "$stage_dir"

for bin_name in zmux zmuxd zmux-connect; do
    cat > "${stage_dir}/${bin_name}" <<EOF
#!/bin/sh
echo "${bin_name} 0.5.0-test"
EOF
    chmod 0755 "${stage_dir}/${bin_name}"
done

tar -czf "${fixture_dir}/zmux-${HOST_TARGET}.tar.gz" -C "$stage_dir" zmux zmuxd zmux-connect
sum_unified="$(sha256_of "${fixture_dir}/zmux-${HOST_TARGET}.tar.gz")"
printf '%s  zmux-%s.tar.gz\n' "$sum_unified" "$HOST_TARGET" > "${fixture_dir}/SHA256SUMS"

install_out="$(sh "$INSTALL_SH" --version v0.5.0 --dir "$install_dir" --base-url "file://${fixture_dir}")"
assert_contains "$install_out" "Installed zmux zmuxd zmux-connect" "unified install output"
assert_contains "$install_out" "export PATH=\"${install_dir}:\$PATH\"" "PATH guidance"

for bin_name in zmux zmuxd zmux-connect; do
    [ -x "${install_dir}/${bin_name}" ] || fail "missing installed binary ${bin_name}"
    ver_out="$("${install_dir}/${bin_name}" --version)"
    [ "$ver_out" = "${bin_name} 0.5.0-test" ] || fail "unexpected version output for ${bin_name}: ${ver_out}"
done
pass "offline unified tarball install with SHA-256 verification"

# 5. Offline split tarballs (v0.4.0 layout: zmuxd + zmux-connect)
split_dir="${TMP_ROOT}/release-split"
split_install="${TMP_ROOT}/bin-split"
mkdir -p "$split_dir"
tar -czf "${split_dir}/zmuxd-${HOST_TARGET}.tar.gz" -C "$stage_dir" zmuxd
tar -czf "${split_dir}/zmux-connect-${HOST_TARGET}.tar.gz" -C "$stage_dir" zmux-connect
sum_d="$(sha256_of "${split_dir}/zmuxd-${HOST_TARGET}.tar.gz")"
sum_c="$(sha256_of "${split_dir}/zmux-connect-${HOST_TARGET}.tar.gz")"
{
    printf '%s  zmuxd-%s.tar.gz\n' "$sum_d" "$HOST_TARGET"
    printf '%s  zmux-connect-%s.tar.gz\n' "$sum_c" "$HOST_TARGET"
} > "${split_dir}/SHA256SUMS"

sh "$INSTALL_SH" --version v0.4.0 --dir "$split_install" --base-url "file://${split_dir}" >/dev/null
[ -x "${split_install}/zmuxd" ] || fail "split install missing zmuxd"
[ -x "${split_install}/zmux-connect" ] || fail "split install missing zmux-connect"
pass "offline split tarball install with SHA-256 verification"

# 6. Corrupted checksum MUST fail loudly without modifying target directory
bad_dir="${TMP_ROOT}/release-corrupt"
protected_target="${TMP_ROOT}/protected-bin"
mkdir -p "$bad_dir" "$protected_target"
printf 'keep-me\n' > "${protected_target}/existing-sentinel"
cp "${fixture_dir}/zmux-${HOST_TARGET}.tar.gz" "${bad_dir}/zmux-${HOST_TARGET}.tar.gz"
printf '0000000000000000000000000000000000000000000000000000000000000000  zmux-%s.tar.gz\n' "$HOST_TARGET" > "${bad_dir}/SHA256SUMS"

corrupt_err=""
if corrupt_err="$(sh "$INSTALL_SH" --version v0.5.0 --dir "$protected_target" --base-url "file://${bad_dir}" 2>&1)"; then
    fail "corrupted checksum unexpectedly succeeded"
fi
assert_contains "$corrupt_err" "checksum mismatch" "corrupt checksum error message"
[ ! -e "${protected_target}/zmux" ] || fail "zmux should not exist after checksum failure"
[ ! -e "${protected_target}/zmuxd" ] || fail "zmuxd should not exist after checksum failure"
[ ! -e "${protected_target}/zmux-connect" ] || fail "zmux-connect should not exist after checksum failure"
[ "$(cat "${protected_target}/existing-sentinel")" = "keep-me" ] || fail "existing target files were altered"
# Verify no leftover temp staging files in protected_target
extra_files="$(find "$protected_target" -mindepth 1 -maxdepth 1 ! -name existing-sentinel)"
[ -z "$extra_files" ] || fail "unexpected leftover files after checksum failure: ${extra_files}"
pass "corrupted checksum fails loudly and leaves target dir untouched"

# 7. Missing target in SHA256SUMS fails loudly without creating target dir
missing_dir="${TMP_ROOT}/release-missing"
missing_target="${TMP_ROOT}/missing-target-bin"
mkdir -p "$missing_dir"
printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  zmux-other-arch.tar.gz\n' > "${missing_dir}/SHA256SUMS"
if sh "$INSTALL_SH" --version v0.5.0 --dir "$missing_target" --base-url "file://${missing_dir}" >/dev/null 2>&1; then
    fail "missing target unexpectedly succeeded"
fi
[ ! -e "$missing_target" ] || fail "target dir must not be created when archive is missing"
pass "missing target fails loudly without creating target dir"

# 8. Also run offline verified install explicitly under dash if present
if command -v dash >/dev/null 2>&1; then
    dash_install="${TMP_ROOT}/bin-dash"
    dash "$INSTALL_SH" --version v0.5.0 --dir "$dash_install" --base-url "file://${fixture_dir}" >/dev/null
    [ -x "${dash_install}/zmux" ] || fail "dash install missing zmux"
    [ -x "${dash_install}/zmuxd" ] || fail "dash install missing zmuxd"
    [ -x "${dash_install}/zmux-connect" ] || fail "dash install missing zmux-connect"
    pass "dash POSIX strict execution"
fi

printf '\nAll %d install.sh tests passed.\n' "$PASS_COUNT"
