#!/bin/bash
set -u
bundle_dir=$(cd -- "$(dirname -- "$0")" && pwd)
setup_root=${HERMES_HOME:-"$HOME/.hermes"}
case "$setup_root" in */profiles/*) setup_root=${setup_root%/profiles/*} ;; esac
setup_python=${HERMES_FLEET_SETUP_PYTHON:-}
if [ -z "$setup_python" ]; then
  for candidate in "$setup_root/hermes-agent/venv/bin/python" "$setup_root/venv/bin/python"; do
    if [ -x "$candidate" ]; then setup_python=$candidate; break; fi
  done
fi
if [ -z "$setup_python" ]; then setup_python=$(command -v python3 || true); fi
if [ -z "$setup_python" ]; then
  echo "Hermes Python was not found. Follow README.txt in this download."
  result=1
else
  "$setup_python" "$bundle_dir/setup.py" "$@"
  result=$?
fi
if [ -t 0 ]; then read -r -p "Press Return to close this window." _; fi
exit "$result"
