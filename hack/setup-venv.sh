#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

python3 -m venv .venv
# shellcheck disable=SC1091
source .venv/bin/activate

pip install --upgrade pip
pip install -r requirements.txt
ansible-galaxy install -r requirements.yml

echo
echo "Done. Activate the venv in new shells with: source .venv/bin/activate"
