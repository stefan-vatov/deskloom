#!/usr/bin/env bash
set -Eeuo pipefail

plugin_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source_checkout=${DESKLOOM_HYPRLOOM_SOURCE:-$HOME/code/hyprloom}
expected_commit=$(sed -n 's/^readonly expected_source_commit="\([^"]*\)"/\1/p' "$plugin_dir/install-helper.sh")
expected_version=$(sed -n 's/^readonly expected_version="\([^"]*\)"/\1/p' "$plugin_dir/install-helper.sh")

if [[ -z "$expected_commit" || -z "$expected_version" ]]; then
  echo "could not read the helper's pinned release metadata" >&2
  exit 1
fi
if [[ ! -d "$source_checkout/.git" ]]; then
  echo "set DESKLOOM_HYPRLOOM_SOURCE to the local hyprloom checkout" >&2
  exit 1
fi
if [[ "$(git -C "$source_checkout" rev-parse HEAD)" != "$expected_commit" ]]; then
  echo "the plugin pin and local hyprloom checkout do not match" >&2
  exit 1
fi

test_root=$(mktemp -d "${TMPDIR:-/tmp}/deskloom-install-test.XXXXXX")
trap 'rm -rf -- "$test_root"' EXIT
fake_bin="$test_root/bin"
fake_home="$test_root/home"
fake_source="$test_root/source"
mkdir -p "$fake_bin" "$fake_home"

# Clone the exact pinned commit so the test never writes into the developer's
# checkout, while still exercising the helper's real source validation.
git clone --quiet --no-hardlinks "$source_checkout" "$fake_source"

cat > "$fake_bin/omarchy-pkg-aur-add" <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >> "$DESKLOOM_AUR_LOG"
SCRIPT
chmod +x "$fake_bin/omarchy-pkg-aur-add"

cat > "$fake_bin/cargo" <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >> "$DESKLOOM_CARGO_LOG"
case "${1:-}" in
  clean)
    exit 0
    ;;
  build)
    mkdir -p "$PWD/target/release"
    cat > "$PWD/target/release/hyprloom" <<'BINARY'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${1:-}" == "--version" ]]; then
  printf 'hyprloom %s\n' "$DESKLOOM_EXPECTED_VERSION"
fi
exit 0
BINARY
    chmod +x "$PWD/target/release/hyprloom"
    ;;
  *)
    echo "unexpected fake cargo invocation: $*" >&2
    exit 1
    ;;
esac
SCRIPT
chmod +x "$fake_bin/cargo"

export DESKLOOM_AUR_LOG="$test_root/aur.log"
export DESKLOOM_CARGO_LOG="$test_root/cargo.log"
export DESKLOOM_EXPECTED_VERSION="$expected_version"

env \
  HOME="$fake_home" \
  PATH="$fake_bin:$PATH" \
  DESKLOOM_HYPRLOOM_SOURCE="$fake_source" \
  "$plugin_dir/install-helper.sh"

installed="$fake_home/.local/bin/hyprloom"
marker="$fake_home/.local/bin/.hyprloom.sha256"
[[ -x "$installed" ]]
[[ "$("$installed" --version)" == "hyprloom $expected_version" ]]
[[ -s "$marker" ]]
[[ "$(wc -l < "$DESKLOOM_AUR_LOG")" -eq 1 ]]
[[ "$(wc -l < "$DESKLOOM_CARGO_LOG")" -eq 2 ]]

# The second invocation must use the verified destination fast path and avoid
# prompting for AUR credentials or rebuilding the binary.
aur_before=$(wc -l < "$DESKLOOM_AUR_LOG")
cargo_before=$(wc -l < "$DESKLOOM_CARGO_LOG")
env \
  HOME="$fake_home" \
  PATH="$fake_bin:$PATH" \
  DESKLOOM_HYPRLOOM_SOURCE="$fake_source" \
  "$plugin_dir/install-helper.sh"
[[ "$(wc -l < "$DESKLOOM_AUR_LOG")" -eq "$aur_before" ]]
[[ "$(wc -l < "$DESKLOOM_CARGO_LOG")" -eq "$cargo_before" ]]

echo "install helper integration checks passed"
