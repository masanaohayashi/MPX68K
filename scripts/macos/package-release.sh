#!/usr/bin/env bash
# Build, sign, notarize, staple, and publish the MPX68K macOS release.
#
# The generated DMG contains:
#   MPX68K.app
#   Applications -> /Applications
#
# A release is always made from a clean commit that is already pushed to the
# configured release remote. Private signing keys and notary credentials are
# kept in the user's Keychain, never in this repository.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"

if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

APP_NAME="${APP_NAME:-}"
SCHEME="${SCHEME:-X68000 macOS}"
XCODE_PROJECT="${XCODE_PROJECT:-${REPO_ROOT}/X68000.xcodeproj}"
DEPENDENCY_PROJECT="${DEPENDENCY_PROJECT:-${REPO_ROOT}/c68k/c68k.xcodeproj}"
DEPENDENCY_SCHEME="${DEPENDENCY_SCHEME:-c68k mac}"
APP_IDENTITY="${APP_IDENTITY:-Developer ID Application: Masanao Hayashi (P5G28RMWUN)}"
TEAM_ID="${TEAM_ID:-P5G28RMWUN}"
NOTARY_PROFILE="${NOTARY_PROFILE:-MPX68KNotary}"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-Release}"
BUILD_ARCHS="${BUILD_ARCHS:-arm64 x86_64}"
RELEASE_BRANCH="${RELEASE_BRANCH:-master}"
RELEASE_REMOTE="${RELEASE_REMOTE:-fork}"
GH_REPO="${GH_REPO:-}"
DIST_DIR="${DIST_DIR:-${REPO_ROOT}/dist}"

TAG_OVERRIDE=""
DRAFT_RELEASE=0
MOUNTED=0
MOUNT_POINT=""

log() {
    printf '==> %s\n' "$*" >&2
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

usage() {
    cat <<'EOF'
Usage: ./scripts/macos/package-release.sh [options]

Builds a signed Universal macOS app, creates a DMG containing MPX68K.app and
an Applications-folder link, notarizes and staples the DMG, then publishes a
GitHub Release with the DMG attached.

Options:
  --tag vVERSION.BUILD   Override the Git tag (default: v<version>.<build>)
  --identity NAME        Developer ID Application identity
  --team-id ID           Apple Developer Team ID
  --notary-profile NAME  notarytool Keychain profile
  --remote NAME          Git remote used for the branch and release tag
  --repo OWNER/REPO      GitHub repository for the Release
  --draft                Leave the GitHub Release as a draft
  -h, --help             Show this help

The following environment variables can also be set in
scripts/macos/config.env:
  APP_NAME, SCHEME, XCODE_PROJECT, DEPENDENCY_PROJECT, DEPENDENCY_SCHEME,
  APP_IDENTITY, TEAM_ID, NOTARY_PROFILE, BUILD_CONFIGURATION, BUILD_ARCHS,
  RELEASE_BRANCH, RELEASE_REMOTE, GH_REPO, DIST_DIR
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tag)
                [[ $# -ge 2 ]] || die "--tag requires an argument"
                TAG_OVERRIDE="$2"
                shift 2
                ;;
            --identity)
                [[ $# -ge 2 ]] || die "--identity requires an argument"
                APP_IDENTITY="$2"
                shift 2
                ;;
            --team-id)
                [[ $# -ge 2 ]] || die "--team-id requires an argument"
                TEAM_ID="$2"
                shift 2
                ;;
            --notary-profile)
                [[ $# -ge 2 ]] || die "--notary-profile requires an argument"
                NOTARY_PROFILE="$2"
                shift 2
                ;;
            --remote)
                [[ $# -ge 2 ]] || die "--remote requires an argument"
                RELEASE_REMOTE="$2"
                shift 2
                ;;
            --repo)
                [[ $# -ge 2 ]] || die "--repo requires an argument"
                GH_REPO="$2"
                shift 2
                ;;
            --draft)
                DRAFT_RELEASE=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "unknown argument: $1 (try --help)"
                ;;
        esac
    done
}

read_project_settings() {
    local build_settings

    log "Reading ${SCHEME} build settings"
    if ! build_settings="$(xcodebuild \
        -showBuildSettings \
        -project "$XCODE_PROJECT" \
        -scheme "$SCHEME" \
        -configuration "$BUILD_CONFIGURATION" 2>&1)"; then
        printf '%s\n' "$build_settings" >&2
        die "could not read Xcode build settings"
    fi

    project_setting() {
        local key="$1"
        awk -v key="$key" \
            '$1 == key && $2 == "=" { value = $0; sub(/^[^=]*= /, "", value); sub(/[[:space:]]+$/, "", value); print value; exit }' \
            <<<"$build_settings"
    }

    MARKETING_VERSION="$(project_setting MARKETING_VERSION)"
    CURRENT_PROJECT_VERSION="$(project_setting CURRENT_PROJECT_VERSION)"
    PRODUCT_NAME="$(project_setting PRODUCT_NAME)"
    PRODUCT_BUNDLE_IDENTIFIER="$(project_setting PRODUCT_BUNDLE_IDENTIFIER)"

    [[ -n "$MARKETING_VERSION" ]] || die "could not read MARKETING_VERSION"
    [[ -n "$CURRENT_PROJECT_VERSION" ]] || die "could not read CURRENT_PROJECT_VERSION"
    [[ -n "$PRODUCT_NAME" ]] || die "could not read PRODUCT_NAME"
    [[ -n "$PRODUCT_BUNDLE_IDENTIFIER" ]] || die "could not read PRODUCT_BUNDLE_IDENTIFIER"

    APP_NAME="${APP_NAME:-$PRODUCT_NAME}"
    [[ "$APP_NAME" == "$PRODUCT_NAME" ]] \
        || die "APP_NAME ($APP_NAME) does not match PRODUCT_NAME ($PRODUCT_NAME)"

    [[ "$MARKETING_VERSION" =~ ^[0-9]+(\.[0-9]+)*([.-][0-9A-Za-z.-]+)?$ ]] \
        || die "invalid MARKETING_VERSION: $MARKETING_VERSION"
    [[ "$CURRENT_PROJECT_VERSION" =~ ^[0-9]+$ ]] \
        || die "invalid CURRENT_PROJECT_VERSION: $CURRENT_PROJECT_VERSION"

    RELEASE_TAG="${TAG_OVERRIDE:-v${MARKETING_VERSION}.${CURRENT_PROJECT_VERSION}}"
    [[ "$RELEASE_TAG" =~ ^v[0-9]+(\.[0-9]+)*([.-][0-9A-Za-z.-]+)?$ ]] \
        || die "invalid release tag: $RELEASE_TAG"
    RELEASE_TITLE="${APP_NAME} ${RELEASE_TAG}"
}

repository_from_remote() {
    local remote_url="$1"

    case "$remote_url" in
        https://github.com/*)
            remote_url="${remote_url#https://github.com/}"
            ;;
        git@github.com:*)
            remote_url="${remote_url#git@github.com:}"
            ;;
        ssh://git@github.com/*)
            remote_url="${remote_url#ssh://git@github.com/}"
            ;;
        *)
            return 1
            ;;
    esac

    remote_url="${remote_url%.git}"
    [[ "$remote_url" =~ ^[^/]+/[^/]+$ ]] || return 1
    printf '%s' "$remote_url"
}

resolve_github_repository() {
    local remote_url

    [[ -n "$GH_REPO" ]] && return
    remote_url="$(git -C "$REPO_ROOT" remote get-url --push "$RELEASE_REMOTE")" \
        || die "could not read push URL for remote '$RELEASE_REMOTE'"
    GH_REPO="$(repository_from_remote "$remote_url")" \
        || die "release remote is not a GitHub repository; set GH_REPO in config.env"
}

check_repository() {
    local current_branch status_text remote_head submodules

    [[ -d "$XCODE_PROJECT" ]] || die "missing Xcode project: $XCODE_PROJECT"
    [[ -d "$DEPENDENCY_PROJECT" ]] || die "missing c68k project: $DEPENDENCY_PROJECT"
    [[ "$BUILD_CONFIGURATION" == "Release" ]] \
        || die "release script requires BUILD_CONFIGURATION=Release"

    git -C "$REPO_ROOT" remote get-url --push "$RELEASE_REMOTE" >/dev/null \
        || die "configured release remote does not exist: $RELEASE_REMOTE"

    current_branch="$(git -C "$REPO_ROOT" branch --show-current)"
    [[ "$current_branch" == "$RELEASE_BRANCH" ]] \
        || die "release must run on branch '$RELEASE_BRANCH' (current: '$current_branch')"

    status_text="$(git -C "$REPO_ROOT" status --porcelain --untracked-files=all)"
    [[ -z "$status_text" ]] || {
        printf '%s\n' "$status_text" >&2
        die "working tree is not clean; commit or revert the changes above first"
    }

    git -C "$REPO_ROOT" fetch --quiet "$RELEASE_REMOTE" "$RELEASE_BRANCH" \
        || die "could not fetch ${RELEASE_REMOTE}/${RELEASE_BRANCH}"
    remote_head="$(git -C "$REPO_ROOT" rev-parse "${RELEASE_REMOTE}/${RELEASE_BRANCH}")"
    [[ "$(git -C "$REPO_ROOT" rev-parse HEAD)" == "$remote_head" ]] \
        || die "HEAD is not equal to ${RELEASE_REMOTE}/${RELEASE_BRANCH}; push the intended commit first"

    git -C "$REPO_ROOT" submodule update --init --recursive \
        || die "could not initialize/update submodules"
    submodules="$(git -C "$REPO_ROOT" submodule status --recursive)"
    if grep -qE '^[+-]' <<<"$submodules"; then
        printf '%s\n' "$submodules" >&2
        die "a submodule is not checked out at the recorded commit"
    fi
    [[ -d "$REPO_ROOT/third_party/ymfm" ]] \
        || die "ymfm submodule is missing: third_party/ymfm"
}

check_release_target() {
    if git -C "$REPO_ROOT" rev-parse --verify --quiet "refs/tags/$RELEASE_TAG" >/dev/null; then
        die "local tag already exists: $RELEASE_TAG"
    fi

    if git -C "$REPO_ROOT" ls-remote --exit-code --refs "$RELEASE_REMOTE" \
        "refs/tags/$RELEASE_TAG" >/dev/null 2>&1; then
        die "remote tag already exists: $RELEASE_TAG"
    else
        local remote_status=$?
        [[ "$remote_status" -eq 2 ]] \
            || die "could not check whether the remote tag exists: $RELEASE_TAG"
    fi

    if gh release view "$RELEASE_TAG" --repo "$GH_REPO" >/dev/null 2>&1; then
        die "GitHub Release already exists: $RELEASE_TAG"
    fi
}

check_signing_identity() {
    local identities

    identities="$(security find-identity -v -p codesigning 2>/dev/null)" \
        || die "could not inspect code-signing identities"
    case "$identities" in
        *"$APP_IDENTITY"*) ;;
        *) die "Developer ID Application identity not found: $APP_IDENTITY" ;;
    esac
}

check_notary_profile() {
    xcrun notarytool history \
        --keychain-profile "$NOTARY_PROFILE" \
        --output-format json >/dev/null 2>&1 \
        || die "notarytool Keychain profile is unavailable: $NOTARY_PROFILE"
}

build_c68k() {
    local build_log="$WORK_DIR/c68k-build.log"
    local dependency_output_dir="${REPO_ROOT}/c68k/build/${BUILD_CONFIGURATION}"

    log "Building c68k (${BUILD_CONFIGURATION}, ${BUILD_ARCHS})"
    mkdir -p "$dependency_output_dir"
    if ! xcodebuild \
        -project "$DEPENDENCY_PROJECT" \
        -scheme "$DEPENDENCY_SCHEME" \
        -configuration "$BUILD_CONFIGURATION" \
        -destination "generic/platform=macOS" \
        ONLY_ACTIVE_ARCH=NO \
        ARCHS="$BUILD_ARCHS" \
        VALID_ARCHS="$BUILD_ARCHS" \
        CONFIGURATION_BUILD_DIR="$dependency_output_dir" \
        2>&1 | tee "$build_log"; then
        die "c68k build failed; see $build_log"
    fi

    [[ -f "$dependency_output_dir/libc68k_mac.a" ]] \
        || die "c68k build did not produce $dependency_output_dir/libc68k_mac.a"
}

archive_app() {
    local archive_log="$WORK_DIR/xcodebuild-archive.log"

    log "Archiving ${APP_NAME} (${BUILD_CONFIGURATION}, ${BUILD_ARCHS})"
    if ! xcodebuild archive \
        -project "$XCODE_PROJECT" \
        -scheme "$SCHEME" \
        -configuration "$BUILD_CONFIGURATION" \
        -destination "generic/platform=macOS" \
        -archivePath "$ARCHIVE_PATH" \
        ONLY_ACTIVE_ARCH=NO \
        ARCHS="$BUILD_ARCHS" \
        VALID_ARCHS="$BUILD_ARCHS" \
        SKIP_INSTALL=NO \
        CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY="$APP_IDENTITY" \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        ENABLE_HARDENED_RUNTIME=YES \
        CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
        OTHER_CODE_SIGN_FLAGS="--timestamp" \
        2>&1 | tee "$archive_log"; then
        die "xcodebuild archive failed; see $archive_log"
    fi

    [[ -d "$APP_PATH" ]] || die "archive did not produce: $APP_PATH"

    log "Verifying Developer ID signature on the archived app"
    codesign --verify --deep --strict --verbose=2 "$APP_PATH"
    local signature_info
    signature_info="$(codesign --display --verbose=4 "$APP_PATH" 2>&1)" \
        || die "codesign display failed"
    case "$signature_info" in
        *"$APP_IDENTITY"*) ;;
        *) die "archived app is not signed with: $APP_IDENTITY" ;;
    esac

    local executable_path
    executable_path="$APP_PATH/Contents/MacOS/$APP_NAME"
    [[ -f "$executable_path" ]] || die "archived executable is missing: $executable_path"
    local app_archs
    app_archs="$(lipo -archs "$executable_path")"
    for architecture in $BUILD_ARCHS; do
        [[ " $app_archs " == *" $architecture "* ]] \
            || die "archived app is missing architecture $architecture (found: $app_archs)"
    done
}

create_dmg() {
    log "Preparing DMG contents"
    mkdir -p "$DMG_STAGE"
    COPYFILE_DISABLE=1 ditto --norsrc --noextattr --noqtn \
        "$APP_PATH" "$DMG_STAGE/${APP_NAME}.app"
    ln -s /Applications "$DMG_STAGE/Applications"

    log "Creating DMG: $DMG_PATH"
    hdiutil create \
        -volname "$DMG_VOLUME_NAME" \
        -srcfolder "$DMG_STAGE" \
        -format UDZO \
        -imagekey zlib-level=9 \
        -ov "$DMG_PATH" \
        >"$WORK_DIR/hdiutil-create.log" 2>&1 \
        || { cat "$WORK_DIR/hdiutil-create.log" >&2; die "hdiutil create failed"; }

    [[ -f "$DMG_PATH" ]] || die "DMG was not created: $DMG_PATH"

    log "Signing DMG"
    codesign --force --sign "$APP_IDENTITY" --timestamp "$DMG_PATH"
    codesign --verify --verbose=2 "$DMG_PATH"
    hdiutil verify "$DMG_PATH"
}

notarize_dmg() {
    local notary_output="$WORK_DIR/notary-submit.json"
    local submission_id

    log "Submitting DMG to Apple Notary Service (profile: $NOTARY_PROFILE)"
    if ! xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait \
        --output-format json 2>&1 | tee "$notary_output"; then
        die "notarytool submit failed; see $notary_output"
    fi

    if ! grep -Eq '"status"[[:space:]]*:[[:space:]]*"Accepted"' "$notary_output"; then
        submission_id="$(sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$notary_output" | head -n 1)"
        if [[ -n "$submission_id" ]]; then
            xcrun notarytool log "$submission_id" \
                --keychain-profile "$NOTARY_PROFILE" \
                "$WORK_DIR/notary-log.json" >/dev/null 2>&1 || true
        fi
        die "notarization was not accepted; see $notary_output and $WORK_DIR/notary-log.json"
    fi

    log "Stapling notarization ticket to DMG"
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
    codesign --verify --verbose=2 "$DMG_PATH"
    hdiutil verify "$DMG_PATH"
}

verify_dmg_contents() {
    local attach_log="$WORK_DIR/hdiutil-attach.log"

    MOUNT_POINT="$WORK_DIR/mounted-dmg"
    mkdir -p "$MOUNT_POINT"
    log "Checking DMG contents and Applications link"
    if ! hdiutil attach "$DMG_PATH" \
        -readonly -nobrowse -noautoopen -mountpoint "$MOUNT_POINT" \
        >"$attach_log" 2>&1; then
        cat "$attach_log" >&2
        die "could not mount the notarized DMG"
    fi
    MOUNTED=1

    [[ -d "$MOUNT_POINT/${APP_NAME}.app" ]] \
        || die "DMG is missing ${APP_NAME}.app"
    [[ -L "$MOUNT_POINT/Applications" ]] \
        || die "DMG is missing Applications link"
    [[ "$(readlink "$MOUNT_POINT/Applications")" == "/Applications" ]] \
        || die "Applications link does not target /Applications"
    codesign --verify --deep --strict --verbose=2 "$MOUNT_POINT/${APP_NAME}.app"

    hdiutil detach "$MOUNT_POINT" >/dev/null \
        || hdiutil detach "$MOUNT_POINT" -force >/dev/null \
        || die "could not detach the DMG after verification"
    MOUNTED=0
}

publish_release() {
    local current_head status_text
    local release_args

    current_head="$(git -C "$REPO_ROOT" rev-parse HEAD)"
    [[ "$current_head" == "$RELEASE_COMMIT" ]] \
        || die "HEAD changed while building; refusing to tag a different commit"
    status_text="$(git -C "$REPO_ROOT" status --porcelain --untracked-files=all)"
    [[ -z "$status_text" ]] \
        || die "working tree changed while building; refusing to publish"

    log "Creating and pushing tag: $RELEASE_TAG"
    git -C "$REPO_ROOT" tag -a "$RELEASE_TAG" "$RELEASE_COMMIT" \
        -m "${APP_NAME} ${RELEASE_TAG}"
    git -C "$REPO_ROOT" push "$RELEASE_REMOTE" "$RELEASE_TAG"

    release_args=(
        release create "$RELEASE_TAG" "$DMG_PATH"
        --repo "$GH_REPO"
        --verify-tag
        --title "$RELEASE_TITLE"
        --generate-notes
    )
    if [[ "$DRAFT_RELEASE" -eq 1 ]]; then
        release_args+=(--draft)
    fi

    log "Creating GitHub Release: $GH_REPO/$RELEASE_TAG"
    gh "${release_args[@]}"
}

cleanup() {
    if [[ "$MOUNTED" -eq 1 && -n "$MOUNT_POINT" ]]; then
        hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 \
            || hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 \
            || true
    fi
}

main() {
    parse_args "$@"

    require_cmd git
    require_cmd xcodebuild
    require_cmd codesign
    require_cmd hdiutil
    require_cmd ditto
    require_cmd lipo
    require_cmd security
    require_cmd xcrun
    require_cmd gh

    read_project_settings
    resolve_github_repository

    check_repository
    gh auth status >/dev/null 2>&1 || die "gh is not authenticated; run gh auth login first"
    check_release_target
    check_signing_identity
    check_notary_profile

    WORK_DIR="${DIST_DIR}/work/${RELEASE_TAG}"
    ARCHIVE_PATH="${WORK_DIR}/${APP_NAME}.xcarchive"
    APP_PATH="${ARCHIVE_PATH}/Products/Applications/${APP_NAME}.app"
    DMG_STAGE="${WORK_DIR}/dmg-root"
    DMG_VOLUME_NAME="${APP_NAME} ${MARKETING_VERSION}"
    DMG_PATH="${DIST_DIR}/${APP_NAME}-${MARKETING_VERSION}.${CURRENT_PROJECT_VERSION}-macOS.dmg"
    RELEASE_COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD)"
    trap cleanup EXIT

    mkdir -p "$DIST_DIR"
    [[ ! -e "$WORK_DIR" ]] || die "work directory already exists: $WORK_DIR"
    [[ ! -e "$DMG_PATH" ]] || die "DMG already exists: $DMG_PATH"
    mkdir -p "$WORK_DIR"

    build_c68k
    archive_app
    create_dmg
    notarize_dmg
    verify_dmg_contents
    publish_release

    cat <<EOF

${APP_NAME} release complete
  tag     : $RELEASE_TAG
  commit  : $RELEASE_COMMIT
  DMG     : $DMG_PATH
  repo    : $GH_REPO
  notary  : $NOTARY_PROFILE
EOF
    if [[ "$DRAFT_RELEASE" -eq 1 ]]; then
        printf '  status  : draft\n'
    else
        printf '  status  : published\n'
    fi
}

main "$@"
