#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_NAME="kmsCoCo.app"
APP_DIR="${REPO_DIR}/${APP_NAME}"
BINARY="${REPO_DIR}/src/kmscoco"
VERSION="1.13.0.dev"

if [[ ! -f "${BINARY}" ]]; then
    echo "Error: Binary ${BINARY} not found. Please build first with 'make'." >&2
    exit 1
fi

echo "==> Packaging ${APP_NAME}..."
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"
mkdir -p "${APP_DIR}/Contents/Frameworks"

# 1. Copy binary
cp "${BINARY}" "${APP_DIR}/Contents/MacOS/kmscoco"
chmod 755 "${APP_DIR}/Contents/MacOS/kmscoco"

# 2. Copy icon and artwork
if [[ -f "${REPO_DIR}/src/macosx/kmscoco.icns" ]]; then
    cp "${REPO_DIR}/src/macosx/kmscoco.icns" "${APP_DIR}/Contents/Resources/kmscoco.icns"
elif [[ -f "${REPO_DIR}/src/macosx/xroar.icns" ]]; then
    cp "${REPO_DIR}/src/macosx/xroar.icns" "${APP_DIR}/Contents/Resources/kmscoco.icns"
fi
if [[ -f "${REPO_DIR}/src/macosx/about_artwork.png" ]]; then
    cp "${REPO_DIR}/src/macosx/about_artwork.png" "${APP_DIR}/Contents/Resources/about_artwork.png"
fi

# 3. Create Info.plist
sed "s/@VERSION@/${VERSION}/g" "${REPO_DIR}/src/macosx/Info.plist.in" > "${APP_DIR}/Contents/Info.plist"

# 4. Copy dynamic libraries
BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
LIB_DIRS=()
[[ -n "${BREW_PREFIX}" ]] && LIB_DIRS+=("${BREW_PREFIX}/lib")
LIB_DIRS+=("/opt/homebrew/lib" "/usr/local/lib")

DYLIB_FOUND=false
for ldir in "${LIB_DIRS[@]}"; do
    if [[ -f "${ldir}/libSDL2-2.0.0.dylib" ]]; then
        echo "==> Found SDL2 dylib in ${ldir}"
        cp "${ldir}/libSDL2-2.0.0.dylib" "${APP_DIR}/Contents/Frameworks/"
        [[ -f "${ldir}/libSDL3.0.dylib" ]] && cp "${ldir}/libSDL3.0.dylib" "${APP_DIR}/Contents/Frameworks/"
        [[ -f "${ldir}/libpng16.16.dylib" ]] && cp "${ldir}/libpng16.16.dylib" "${APP_DIR}/Contents/Frameworks/"
        if [[ -f "${APP_DIR}/Contents/Frameworks/libSDL3.0.dylib" ]]; then
            (cd "${APP_DIR}/Contents/Frameworks" && ln -sf libSDL3.0.dylib libSDL3.dylib)
        fi
        DYLIB_FOUND=true
        break
    fi
done

if [[ "${DYLIB_FOUND}" == "false" && -d "${REPO_DIR}/XRoARM.app/Contents/Frameworks" ]]; then
    cp -R "${REPO_DIR}/XRoARM.app/Contents/Frameworks/"* "${APP_DIR}/Contents/Frameworks/"
fi

# Ensure permissions
chmod 755 "${APP_DIR}/Contents/Frameworks"/*.dylib* 2>/dev/null || true

# 5. Fix install names with install_name_tool
for prefix in "/opt/homebrew" "/usr/local" "${BREW_PREFIX}"; do
    [[ -z "${prefix}" ]] && continue
    install_name_tool -change "${prefix}/opt/sdl2/lib/libSDL2-2.0.0.dylib" \
        @executable_path/../Frameworks/libSDL2-2.0.0.dylib "${APP_DIR}/Contents/MacOS/kmscoco" 2>/dev/null || true
    install_name_tool -change "${prefix}/lib/libSDL2-2.0.0.dylib" \
        @executable_path/../Frameworks/libSDL2-2.0.0.dylib "${APP_DIR}/Contents/MacOS/kmscoco" 2>/dev/null || true
    install_name_tool -change "${prefix}/opt/libpng/lib/libpng16.16.dylib" \
        @executable_path/../Frameworks/libpng16.16.dylib "${APP_DIR}/Contents/MacOS/kmscoco" 2>/dev/null || true
    install_name_tool -change "${prefix}/lib/libpng16.16.dylib" \
        @executable_path/../Frameworks/libpng16.16.dylib "${APP_DIR}/Contents/MacOS/kmscoco" 2>/dev/null || true
    install_name_tool -change "${prefix}/lib/libSDL3.0.dylib" \
        @loader_path/libSDL3.dylib "${APP_DIR}/Contents/Frameworks/libSDL2-2.0.0.dylib" 2>/dev/null || true
done

install_name_tool -id @executable_path/../Frameworks/libSDL2-2.0.0.dylib \
    "${APP_DIR}/Contents/Frameworks/libSDL2-2.0.0.dylib" 2>/dev/null || true
install_name_tool -id @loader_path/libSDL3.dylib \
    "${APP_DIR}/Contents/Frameworks/libSDL3.0.dylib" 2>/dev/null || true
install_name_tool -id @executable_path/../Frameworks/libpng16.16.dylib \
    "${APP_DIR}/Contents/Frameworks/libpng16.16.dylib" 2>/dev/null || true

# 6. Ad-hoc code sign
echo "==> Signing ${APP_NAME}..."
codesign --force --deep --sign - "${APP_DIR}"
codesign --verify --deep --strict --verbose=2 "${APP_DIR}"

echo "==> Successfully packaged ${APP_DIR}"

if [[ "${1:-}" == "--install" ]]; then
    DEST="/Applications/${APP_NAME}"
    echo "==> Installing to ${DEST}..."
    rm -rf "${DEST}"
    cp -R "${APP_DIR}" "${DEST}"
    echo "==> Successfully installed to ${DEST}"
fi
