#!/usr/bin/env bash
set -euo pipefail

# Migration script: nix-devshells → per-project devenv
# Usage: ./bootstrap.sh <project-dir> [project-dir...]
#
# For each project:
#   1. Reads .ruby-version to determine Ruby version
#   2. Selects modern or legacy flake template based on Ruby version
#   3. Copies devenv template files (flake.nix, devenv.nix, .envrc)
#   4. Patches devenv.nix with the correct Ruby version/package
#   5. Adds .gems, .direnv, .Gemfile.nix to git exclude
#   6. Removes old nix-devshells .envrc
#   7. Runs direnv allow

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="${SCRIPT_DIR}"

# Ruby version → nixpkgs channel mapping for legacy
declare -A LEGACY_CHANNELS=(
  ["2.6"]="nixos-21.05"
  ["2.7"]="nixos-22.11"
)

# Ruby version → nix package attribute for legacy
declare -A LEGACY_PACKAGES=(
  ["2.6"]="ruby_2_6"
  ["2.7"]="ruby_2_7"
)

# Ruby version → nixpkgs attribute for modern (3.2+)
ruby_nix_pkg() {
  local version="$1"
  echo "ruby_${version//./_}"
}

normalize_ruby_version() {
  local raw="$1"
  raw="${raw#ruby-}"
  echo "$raw" | grep -oE '^[0-9]+\.[0-9]+'
}

is_legacy_ruby() {
  [[ -n "${LEGACY_CHANNELS[$1]+x}" ]]
}

migrate_project() {
  local project_dir="$1"

  if [[ ! -d "$project_dir/.git" ]]; then
    echo "SKIP $project_dir (not a git repo)"
    return
  fi

  if [[ ! -f "$project_dir/Gemfile" ]]; then
    echo "SKIP $project_dir (no Gemfile)"
    return
  fi

  echo "Migrating: $project_dir"

  # Detect Ruby version
  local ruby_version="3.4"
  if [[ -f "$project_dir/.ruby-version" ]]; then
    ruby_version="$(normalize_ruby_version "$(cat "$project_dir/.ruby-version")")"
  fi
  echo "  Ruby version: $ruby_version"

  # Copy the right flake template
  if is_legacy_ruby "$ruby_version"; then
    local channel="${LEGACY_CHANNELS[$ruby_version]}"
    local ruby_pkg="${LEGACY_PACKAGES[$ruby_version]}"
    echo "  Legacy Ruby — using nixpkgs channel: $channel"

    # Use legacy flake template and patch the channel
    cp "$TEMPLATE_DIR/flake-legacy.nix" "$project_dir/flake.nix"
    sed -i "s|nixos-22.11|$channel|" "$project_dir/flake.nix"

    # Copy devenv.nix and patch for legacy ruby package
    cp "$TEMPLATE_DIR/devenv.nix" "$project_dir/devenv.nix"
    sed -i "s/legacyPkgs.ruby_2_7/legacyPkgs.$ruby_pkg/" "$project_dir/devenv.nix"
  else
    # Modern Ruby — use standard template, patch ruby package
    local nix_pkg
    nix_pkg="$(ruby_nix_pkg "$ruby_version")"
    cp "$TEMPLATE_DIR/flake.nix" "$project_dir/flake.nix"
    cp "$TEMPLATE_DIR/devenv.nix" "$project_dir/devenv.nix"
    sed -i "s/pkgs.ruby_3_4/pkgs.$nix_pkg/" "$project_dir/devenv.nix"
  fi

  cp "$TEMPLATE_DIR/.envrc" "$project_dir/.envrc"

  # Git exclude (don't pollute .gitignore)
  local exclude_file="$project_dir/.git/info/exclude"
  mkdir -p "$(dirname "$exclude_file")"
  for pattern in .gems .direnv .Gemfile.nix .devenv .devenv.flake.nix; do
    grep -qxF "$pattern" "$exclude_file" 2>/dev/null || echo "$pattern" >> "$exclude_file"
  done

  # Allow direnv
  (cd "$project_dir" && direnv allow)

  echo "  Done. Files added: flake.nix, devenv.nix, .envrc"
}

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 <project-dir> [project-dir...]"
  echo "       $0 ~/dev/clients/digitpro/projects/*"
  exit 1
fi

for dir in "$@"; do
  migrate_project "$dir"
done
