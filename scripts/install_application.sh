#!/bin/bash
#
# Build SleepControl, replace /Applications/SleepControl.app, and open the application.
#
# Usage: scripts/install_application.sh
#
# The script does not run sudo. SleepControl asks for the administrator password once,
# on first use, to install its sudoers rule. The script stops when the build fails.

set -euo pipefail

readonly APPLICATION_NAME="SleepControl"
readonly BUNDLE_NAME="SleepControl.app"
readonly BUNDLE_IDENTIFIER="local.sleepcontrol.SleepControl"
readonly INSTALLED_BUNDLE_PATH="/Applications/${BUNDLE_NAME}"
readonly QUIT_TIMEOUT_SECONDS=10

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIRECTORY

INSTALL_TEMPORARY_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/sleepcontrol_install.XXXXXX")"
readonly INSTALL_TEMPORARY_DIRECTORY
trap 'rm -rf "${INSTALL_TEMPORARY_DIRECTORY}"' EXIT

quit_running_application() {
  local attempt=0

  if ! pgrep -x "${APPLICATION_NAME}" >/dev/null 2>&1; then
    return 0
  fi

  echo "Quitting the running ${APPLICATION_NAME}."
  osascript -e "tell application id \"${BUNDLE_IDENTIFIER}\" to quit" >/dev/null 2>&1 || true

  while pgrep -x "${APPLICATION_NAME}" >/dev/null 2>&1; do
    if [ "${attempt}" -ge "${QUIT_TIMEOUT_SECONDS}" ]; then
      return 1
    fi
    sleep 1
    attempt=$((attempt + 1))
  done
  return 0
}

echo "SleepControl asks for the administrator password once, on first use."
echo "The prompt appears when you turn on Keep Awake with Lid Closed."
echo "This script does not ask for a password."

echo "Building ${APPLICATION_NAME} in a temporary directory."
"${SCRIPT_DIRECTORY}/build_application.sh" "${INSTALL_TEMPORARY_DIRECTORY}"

if ! quit_running_application; then
  echo "error: ${APPLICATION_NAME} is still running after the quit command." >&2
  echo "Quit it from the menu bar, then run this script again." >&2
  exit 1
fi

echo "Replacing ${INSTALLED_BUNDLE_PATH}."
rm -rf "${INSTALLED_BUNDLE_PATH}"
if ! /usr/bin/ditto "${INSTALL_TEMPORARY_DIRECTORY}/${BUNDLE_NAME}" "${INSTALLED_BUNDLE_PATH}"; then
  echo "error: could not copy the application to /Applications." >&2
  exit 1
fi

echo "Opening ${INSTALLED_BUNDLE_PATH}."
/usr/bin/open "${INSTALLED_BUNDLE_PATH}"
echo "Installed ${INSTALLED_BUNDLE_PATH}."
