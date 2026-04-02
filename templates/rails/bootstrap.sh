#!/usr/bin/env bash
set -euo pipefail

# Migration script: nix-devshells → per-project devenv (Ruby 3.2+ only)
# Usage: ./bootstrap.sh <project-dir> [project-dir...]
#
# For each project:
#   1. Reads .ruby-version to determine Ruby version
#   2. Skips legacy Ruby (2.6, 2.7) — use centralized devShells instead
#   3. Copies devenv template files (flake.nix, devenv.nix, .envrc)
#   4. Patches devenv.nix with the correct Ruby package
#   5. Adds .gems, .direnv, .Gemfile.nix to git exclude
#   6. Runs direnv allow

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="${SCRIPT_DIR}"

# Legacy Ruby versions — not supported by devenv
declare -A LEGACY_VERSIONS=(
  ["2.6"]=1
  ["2.7"]=1
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

  # Skip legacy Ruby — devenv is incompatible
  if [[ -n "${LEGACY_VERSIONS[$ruby_version]+x}" ]]; then
    echo "  SKIP — Ruby $ruby_version is not supported by devenv. Use centralized devShells instead:"
    echo "         echo 'use flake \"github:abstracts33d/nix-devshells#rails-ruby${ruby_version//./ }\"' > .envrc"
    return
  fi

  # Modern Ruby — copy template and patch ruby package
  local nix_pkg
  nix_pkg="$(ruby_nix_pkg "$ruby_version")"
  cp "$TEMPLATE_DIR/flake.nix" "$project_dir/flake.nix"
  cp "$TEMPLATE_DIR/devenv.nix" "$project_dir/devenv.nix"
  sed -i "s/pkgs.ruby_3_4/pkgs.$nix_pkg/" "$project_dir/devenv.nix"

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
