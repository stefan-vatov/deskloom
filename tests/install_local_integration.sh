#!/usr/bin/env bash
set -Eeuo pipefail
plugin_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
exec node --test "$plugin_dir/tests/install_local.test.mjs"
