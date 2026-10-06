#!/usr/bin/env bash
# Synthetic bundle-preparation tests. No network, compiler, or account access.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/bin" "${WORK}/repo/Scripts" "${WORK}/repo/Resources"
cp "${ROOT}/Scripts/make-app.sh" "${WORK}/repo/Scripts/"
touch "${WORK}/repo/Resources/AppIcon.icns"

cat > "${WORK}/bin/mock" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
name="${0##*/}"
printf '%s\n' "$name" >> "$TEST_CALLS"
case "$name" in
    uname)
        if [ "$1" = -s ]; then
            echo Darwin
        elif [ "$TEST_CASE" = unsupported-arch ]; then
            echo x86_64
        else
            echo arm64
        fi ;;
    sw_vers)
        if [ "$TEST_CASE" = unsupported-os ]; then echo 12.7; else echo 27.0.1; fi ;;
    sysctl)
        if [ "$TEST_CASE" = unsupported-arch ]; then echo 0; else echo 1; fi ;;
    curl)
        [ "$TEST_CASE" != download-failed ] || exit 22
        printf 'synthetic archive\n' > "${!#}" ;;
    shasum)
        cat >/dev/null
        [ "$TEST_CASE" != checksum-failed ] ;;
    ditto)
        if [ "$1" = -x ]; then
            mkdir -p "$4/MeterUsage.app/Contents/MacOS"
            [ "$TEST_CASE" != invalid-bundle ] || exit 0
            printf '#!/bin/sh\nexit 0\n' > "$4/MeterUsage.app/Contents/MacOS/meterusage"
            chmod +x "$4/MeterUsage.app/Contents/MacOS/meterusage"
        else
            cp -R "$1" "$2"
        fi ;;
    codesign)
        [ "$TEST_CASE" != signature-failed ] ;;
    swift)
        echo 'Swift must not run during default preparation' >&2
        exit 99 ;;
esac
MOCK
chmod +x "${WORK}/bin/mock"
for tool in uname sw_vers sysctl curl shasum ditto codesign swift; do
    ln -s mock "${WORK}/bin/${tool}"
done

run_case() {
    local scenario="$1" expected="$2" result=0
    shift 2
    rm -rf "${WORK}/repo/dist"
    mkdir -p "${WORK}/repo/dist/MeterUsage.app"
    printf 'existing bundle\n' > "${WORK}/repo/dist/MeterUsage.app/preserve"
    : > "${WORK}/calls"
    PATH="${WORK}/bin:$PATH" TEST_CASE="$scenario" TEST_CALLS="${WORK}/calls" \
        bash "${WORK}/repo/Scripts/make-app.sh" "$@" > "${WORK}/output" 2>&1 || result=$?
    if [ "$result" -ne "$expected" ]; then
        cat "${WORK}/output" >&2
        echo "FAIL: $scenario exited $result, expected $expected" >&2
        exit 1
    fi
    if [ "$scenario" = source-build ]; then
        grep -qx swift "${WORK}/calls"
    else
        if grep -qx swift "${WORK}/calls"; then
            echo "FAIL: $scenario invoked Swift" >&2
            exit 1
        fi
    fi
    if [ "$expected" -eq 0 ]; then
        test -x "${WORK}/repo/dist/MeterUsage.app/Contents/MacOS/meterusage"
        test ! -e "${WORK}/repo/dist/MeterUsage.app/preserve"
    else
        test -f "${WORK}/repo/dist/MeterUsage.app/preserve"
    fi
    echo "PASS: $scenario"
}

run_case default 0
run_case download-failed 22
run_case checksum-failed 1
run_case invalid-bundle 1
run_case signature-failed 1
run_case unsupported-os 1
run_case unsupported-arch 1
run_case invalid-option 2 --invalid
run_case source-build 99 --build-from-source
