#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/build/unsigned"
APP_PATH="${BUILD_DIR}/DerivedData/Build/Products/Release-iphoneos/NexaPortfolio.app"
PACKAGE_DIR="${BUILD_DIR}/package"
IPA_PATH="${PROJECT_DIR}/build/NexaPortfolio-unsigned.ipa"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Erreur : la compilation iOS nécessite macOS et Xcode." >&2
  exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "Erreur : Xcode et ses outils en ligne de commande sont requis." >&2
  exit 1
fi

rm -rf "${BUILD_DIR}"
mkdir -p "${PACKAGE_DIR}/Payload" "${PROJECT_DIR}/build"

xcodebuild \
  -project "${PROJECT_DIR}/NexaPortfolio.xcodeproj" \
  -scheme NexaPortfolio \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath "${BUILD_DIR}/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  clean build

if [[ ! -d "${APP_PATH}" ]]; then
  echo "Erreur : NexaPortfolio.app n’a pas été produit." >&2
  exit 1
fi

cp -R "${APP_PATH}" "${PACKAGE_DIR}/Payload/NexaPortfolio.app"
rm -f "${IPA_PATH}"
(
  cd "${PACKAGE_DIR}"
  /usr/bin/zip -qry "${IPA_PATH}" Payload
)

echo "IPA non signé créé : ${IPA_PATH}"
