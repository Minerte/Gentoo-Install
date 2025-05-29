set -e # Exit immediately if a command exits with a non-zero status.
set -u # Treat unset variables as an error when substituting.
set -o pipefail # Pipestatus: exit status of the last command that threw a non-zero exit code is returned.

# --- Configuration Loading ---
CONFIG_FILE="gentoo.conf"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Configuration file '$CONFIG_FILE' not found!"
    exit 1
fi
source "$CONFIG_FILE"
echo "Configuration loaded from '$CONFIG_FILE'."

# --- Basic Validation ---
if [ -z "$BOOT_DRIVE" ] || [ -z "$ROOT_DRIVE" ]; then
    echo "ERROR: BOOT_DRIVE and ROOT_DRIVE must be set in '$CONFIG_FILE'."
    exit 1
fi
if [ "$BOOT_DRIVE" == "$ROOT_DRIVE" ]; then
    echo "ERROR: BOOT_DRIVE and ROOT_DRIVE cannot be the same device."
    exit 1
fi
if [ ! -b "$BOOT_DRIVE" ]; then
    echo "ERROR: Boot drive '$BOOT_DRIVE' is not a block device or does not exist."
    exit 1
fi
if [ ! -b "$ROOT_DRIVE" ]; then
    echo "ERROR: Root drive '$ROOT_DRIVE' is not a block device or does not exist."
    exit 1
fi