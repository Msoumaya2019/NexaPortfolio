#!/bin/bash
set -euo pipefail

if [[ $# -lt 3 || $# -gt 4 ]]; then
  echo "Usage: $0 <unsigned.ipa> <identité de signature> <profil.mobileprovision> [sortie.ipa]" >&2
  exit 1
fi

UNSIGNED_IPA="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
SIGNING_IDENTITY="$2"
PROFILE_PATH="$(cd "$(dirname "$3")" && pwd)/$(basename "$3")"
if [[ $# -eq 4 ]]; then
  OUTPUT_IPA="$(cd "$(dirname "$4")" && pwd)/$(basename "$4")"
else
  OUTPUT_IPA="${UNSIGNED_IPA%.ipa}-signed.ipa"
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Erreur : la signature iOS nécessite macOS." >&2
  exit 1
fi

if [[ ! -f "${UNSIGNED_IPA}" ]]; then
  echo "Erreur : IPA introuvable : ${UNSIGNED_IPA}" >&2
  exit 1
fi

if [[ ! -f "${PROFILE_PATH}" ]]; then
  echo "Erreur : profil introuvable : ${PROFILE_PATH}" >&2
  exit 1
fi

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TEMP_DIR}"' EXIT

/usr/bin/unzip -q "${UNSIGNED_IPA}" -d "${TEMP_DIR}"
APP_CANDIDATES=("${TEMP_DIR}"/Payload/*.app)
if [[ ${#APP_CANDIDATES[@]} -ne 1 || ! -d "${APP_CANDIDATES[0]}" ]]; then
  echo "Erreur : l’archive doit contenir exactement une application dans Payload." >&2
  exit 1
fi
APP_PATH="${APP_CANDIDATES[0]}"

/usr/bin/security cms -D -i "${PROFILE_PATH}" > "${TEMP_DIR}/profile.plist"
/usr/libexec/PlistBuddy -x -c "Print :Entitlements" "${TEMP_DIR}/profile.plist" > "${TEMP_DIR}/entitlements.plist"

PROFILE_APP_ID="$(/usr/libexec/PlistBuddy -c "Print :Entitlements:application-identifier" "${TEMP_DIR}/profile.plist")"
PROFILE_BUNDLE_PATTERN="${PROFILE_APP_ID#*.}"
APP_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "${APP_PATH}/Info.plist")"

if [[ "${PROFILE_BUNDLE_PATTERN}" == *"*" ]]; then
  PROFILE_PREFIX="${PROFILE_BUNDLE_PATTERN%\*}"
  if [[ "${APP_BUNDLE_ID}" != "${PROFILE_PREFIX}"* ]]; then
    echo "Erreur : le profil ${PROFILE_BUNDLE_PATTERN} ne couvre pas ${APP_BUNDLE_ID}." >&2
    exit 1
  fi
elif [[ "${PROFILE_BUNDLE_PATTERN}" != "${APP_BUNDLE_ID}" ]]; then
  echo "Erreur : le profil cible ${PROFILE_BUNDLE_PATTERN}, mais l’app utilise ${APP_BUNDLE_ID}." >&2
  exit 1
fi

cp "${PROFILE_PATH}" "${APP_PATH}/embedded.mobileprovision"
rm -rf "${APP_PATH}/_CodeSignature"

/usr/bin/codesign \
  --force \
  --sign "${SIGNING_IDENTITY}" \
  --entitlements "${TEMP_DIR}/entitlements.plist" \
  --timestamp=none \
  "${APP_PATH}"

/usr/bin/codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

rm -f "${OUTPUT_IPA}"
(
  cd "${TEMP_DIR}"
  /usr/bin/zip -qry "${OUTPUT_IPA}" Payload
)

echo "IPA signé créé : ${OUTPUT_IPA}"
