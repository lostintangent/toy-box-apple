#!/bin/bash
set +x
set -euo pipefail
password=""
if ! IFS= read -r -s -p "$1" password && [[ -z "$password" ]]; then
    printf '\nUnable to read the app-specific password.\n' >&2
    exit 1
fi
printf '\n' >&2
[[ -n "$password" ]] || { echo "The app-specific password must not be empty." >&2; exit 1; }
printf '%s' "$password"
