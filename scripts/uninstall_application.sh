#!/bin/bash
#
# Remove SleepControl. The script restores normal sleep, quits the application,
# removes the application bundle and the sudoers rule, and checks that sudo
# no longer runs pmset without a password.
#
# Usage: scripts/uninstall_application.sh
#
# Every step runs, even when an earlier step fails. The script exits with status 1
# when any step fails. sudo asks for the administrator password in the terminal.

set -uo pipefail

readonly APPLICATION_NAME="SleepControl"
readonly BUNDLE_IDENTIFIER="local.sleepcontrol.SleepControl"
readonly INSTALLED_BUNDLE_PATH="/Applications/SleepControl.app"
readonly SUDOERS_DROP_IN_PATH="/etc/sudoers.d/sleepcontrol"
readonly SUDO_PATH="/usr/bin/sudo"
readonly PMSET_PATH="/usr/bin/pmset"
readonly VISUDO_PATH="/usr/sbin/visudo"
readonly QUIT_TIMEOUT_SECONDS=10

FAILURE_COUNT=0

record_failure() {
  echo "error: $1" >&2
  FAILURE_COUNT=$((FAILURE_COUNT + 1))
}

quit_running_application() {
  local attempt=0

  if ! /usr/bin/pgrep -x "${APPLICATION_NAME}" >/dev/null 2>&1; then
    echo "${APPLICATION_NAME} is not running."
    return 0
  fi

  echo "Sending the quit command to ${APPLICATION_NAME}."
  /usr/bin/osascript -e "tell application id \"${BUNDLE_IDENTIFIER}\" to quit" >/dev/null 2>&1 || true

  while /usr/bin/pgrep -x "${APPLICATION_NAME}" >/dev/null 2>&1; do
    if [ "${attempt}" -ge "${QUIT_TIMEOUT_SECONDS}" ]; then
      return 1
    fi
    /bin/sleep 1
    attempt=$((attempt + 1))
  done

  echo "${APPLICATION_NAME} has quit."
  return 0
}

echo "Step 1 of 7: Restore normal sleep."
if "${SUDO_PATH}" -n "${PMSET_PATH}" -a disablesleep 0 >/dev/null 2>&1; then
  echo "Sleep prevention is off."
elif "${SUDO_PATH}" "${PMSET_PATH}" -a disablesleep 0; then
  echo "Sleep prevention is off."
else
  record_failure "could not restore normal sleep. Run: sudo /usr/bin/pmset -a disablesleep 0"
fi

echo "Step 2 of 7: Quit ${APPLICATION_NAME}."
if ! quit_running_application; then
  record_failure "${APPLICATION_NAME} is still running. Quit it from the menu bar."
fi

echo "Step 3 of 7: Remove ${INSTALLED_BUNDLE_PATH}."
if [ -e "${INSTALLED_BUNDLE_PATH}" ]; then
  if rm -rf "${INSTALLED_BUNDLE_PATH}"; then
    echo "Application bundle removed."
  else
    record_failure "could not remove ${INSTALLED_BUNDLE_PATH}."
  fi
else
  echo "Application bundle was not found."
fi

echo "Step 4 of 7: Remove the sudoers rule."
if [ -e "${SUDOERS_DROP_IN_PATH}" ]; then
  if "${SUDO_PATH}" /bin/rm -f "${SUDOERS_DROP_IN_PATH}"; then
    echo "Sudoers rule removed."
  else
    record_failure "could not remove ${SUDOERS_DROP_IN_PATH}."
  fi
else
  echo "Sudoers rule was not found."
fi

echo "Step 5 of 7: Check the sudoers syntax."
if "${SUDO_PATH}" "${VISUDO_PATH}" -c; then
  echo "Sudoers syntax is valid."
else
  record_failure "the sudoers syntax check failed. Run: sudo visudo -c"
fi

echo "Step 6 of 7: Clear cached sudo credentials."
if "${SUDO_PATH}" -k; then
  echo "Cached sudo credentials are cleared."
else
  record_failure "could not clear cached sudo credentials. Run: sudo -k"
fi

echo "Step 7 of 7: Prove that sudo no longer runs pmset without a password."
if "${SUDO_PATH}" -n "${PMSET_PATH}" -a disablesleep 0 >/dev/null 2>&1; then
  record_failure "sudo still runs pmset without a password. Check the sudoers files."
else
  echo "Revocation confirmed."
fi

echo ""
echo "Saved preferences were not removed. To delete them, run:"
echo "  defaults delete ${BUNDLE_IDENTIFIER}"
echo "If Launch at Login was on, remove SleepControl in System Settings under General, Login Items."

echo ""
if [ "${FAILURE_COUNT}" -eq 0 ]; then
  echo "Uninstall finished. All steps succeeded."
  exit 0
fi
echo "Uninstall finished with ${FAILURE_COUNT} failed step(s). Read the errors above." >&2
exit 1
