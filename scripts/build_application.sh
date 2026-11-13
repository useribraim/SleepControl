#!/bin/bash
#
# Compile SleepControl with swiftc, assemble SleepControl.app, and sign it ad hoc.
#
# Usage: scripts/build_application.sh [destination_directory]
#
# The default destination directory is <repository>/build. The script does not run sudo.
# A failed build leaves an existing application bundle unchanged.

set -euo pipefail

readonly APPLICATION_NAME="SleepControl"
readonly BUNDLE_NAME="SleepControl.app"

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "${SCRIPT_DIRECTORY}/.." && pwd)"
readonly SCRIPT_DIRECTORY
readonly REPOSITORY_ROOT

if [ "$#" -gt 1 ]; then
  echo "usage: $(basename "$0") [destination_directory]" >&2
  exit 2
fi

if ! command -v swiftc >/dev/null 2>&1; then
  echo "error: swiftc was not found." >&2
  echo "Install the Command Line Tools with: xcode-select --install" >&2
  exit 1
fi

readonly INFO_PROPERTY_LIST_PATH="${REPOSITORY_ROOT}/Info.plist"
if [ ! -f "${INFO_PROPERTY_LIST_PATH}" ]; then
  echo "error: Info.plist was not found at ${INFO_PROPERTY_LIST_PATH}." >&2
  exit 1
fi

shopt -s nullglob
SWIFT_SOURCE_FILES=("${REPOSITORY_ROOT}/Sources/"*.swift)
shopt -u nullglob
if [ "${#SWIFT_SOURCE_FILES[@]}" -eq 0 ]; then
  echo "error: no Swift source files were found in ${REPOSITORY_ROOT}/Sources." >&2
  exit 1
fi

DESTINATION_ARGUMENT="${1:-${REPOSITORY_ROOT}/build}"
mkdir -p "${DESTINATION_ARGUMENT}"
DESTINATION_DIRECTORY="$(cd "${DESTINATION_ARGUMENT}" && pwd)"
readonly DESTINATION_DIRECTORY

BUILD_TEMPORARY_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/sleepcontrol_build.XXXXXX")"
readonly BUILD_TEMPORARY_DIRECTORY
trap 'rm -rf "${BUILD_TEMPORARY_DIRECTORY}"' EXIT

readonly COMPILED_EXECUTABLE_PATH="${BUILD_TEMPORARY_DIRECTORY}/${APPLICATION_NAME}"
readonly COMPILER_LOG_PATH="${BUILD_TEMPORARY_DIRECTORY}/swiftc_output.log"

echo "Compiling ${APPLICATION_NAME} from ${#SWIFT_SOURCE_FILES[@]} source files."
if ! swiftc -O -parse-as-library -target arm64-apple-macos13.0 \
  -framework AppKit -framework IOKit -framework ServiceManagement \
  "${SWIFT_SOURCE_FILES[@]}" -o "${COMPILED_EXECUTABLE_PATH}" >"${COMPILER_LOG_PATH}" 2>&1; then
  cat "${COMPILER_LOG_PATH}" >&2
  echo "error: the compilation failed." >&2
  exit 1
fi

cat "${COMPILER_LOG_PATH}"
if grep -q "warning:" "${COMPILER_LOG_PATH}"; then
  echo "error: the compilation produced warnings. The build must produce zero warnings." >&2
  exit 1
fi

readonly STAGED_BUNDLE_PATH="${BUILD_TEMPORARY_DIRECTORY}/${BUNDLE_NAME}"
mkdir -p "${STAGED_BUNDLE_PATH}/Contents/MacOS"
cp "${COMPILED_EXECUTABLE_PATH}" "${STAGED_BUNDLE_PATH}/Contents/MacOS/${APPLICATION_NAME}"
cp "${INFO_PROPERTY_LIST_PATH}" "${STAGED_BUNDLE_PATH}/Contents/Info.plist"

echo "Signing ${BUNDLE_NAME} with an ad hoc signature."
codesign --force --sign - "${STAGED_BUNDLE_PATH}"

readonly FINAL_BUNDLE_PATH="${DESTINATION_DIRECTORY}/${BUNDLE_NAME}"
echo "Replacing ${FINAL_BUNDLE_PATH}."
rm -rf "${FINAL_BUNDLE_PATH}"
mv "${STAGED_BUNDLE_PATH}" "${FINAL_BUNDLE_PATH}"

echo "Verifying the code signature."
if ! codesign --verify --strict --verbose=2 "${FINAL_BUNDLE_PATH}"; then
  rm -rf "${FINAL_BUNDLE_PATH}"
  echo "error: the code signature failed verification." >&2
  exit 1
fi

echo "Built ${FINAL_BUNDLE_PATH}"
