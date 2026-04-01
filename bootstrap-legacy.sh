#!/usr/bin/env bash
set -euo pipefail

DEVSHELLS_FLAKE="${DEVSHELLS_FLAKE:-github:abstracts33d/nix-devshells}"

normalize_ruby_version() {
  local raw="$1"
  # Strip "ruby-" prefix if present, then keep major.minor
  raw="${raw#ruby-}"
  echo "$raw" | grep -oE '^[0-9]+\.[0-9]+'
}

ruby_to_shell_name() {
  # "3.4" -> "rails-ruby34", "2.7" -> "rails-ruby27"
  echo "rails-ruby${1//./}"
}

bootstrap_project() {
  local project_dir="$1"
  local project_name
  project_name="$(basename "$project_dir")"

  # Find Ruby version
  local ruby_version="3.4" # default
  if [[ -f "$project_dir/.ruby-version" ]]; then
    ruby_version="$(normalize_ruby_version "$(cat "$project_dir/.ruby-version")")"
  fi

  local shell_name
  shell_name="$(ruby_to_shell_name "$ruby_version")"

  # Write .envrc — references devShells flake, no local flake needed
  cat >"$project_dir/.envrc" <<EOF
use flake "${DEVSHELLS_FLAKE}#${shell_name}"
EOF

  # Exclude direnv cache and gems from git
  if [[ -d "$project_dir/.git" ]]; then
    local exclude="$project_dir/.git/info/exclude"
    mkdir -p "$(dirname "$exclude")"
    for f in .gems .direnv; do
      grep -qxF "$f" "$exclude" 2>/dev/null || echo "$f" >>"$exclude"
    done
    # Clean up stale entries from previous bootstrap approach
    sed -i '/^flake\.nix$/d; /^flake\.lock$/d' "$exclude"
    # Remove leftover local flake files
    rm -f "$project_dir/flake.nix" "$project_dir/flake.lock"
  fi

  # Allow direnv
  (cd "$project_dir" && direnv allow)

  echo "  $project_name → ${shell_name} (Ruby $ruby_version)"
}

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 <project-dir> [project-dir...]"
  echo "Example: $0 ~/dev/clients/digitpro/projects/*"
  exit 1
fi

echo "Bootstrapping Rails devShells..."
echo ""

for dir in "$@"; do
  [[ -d $dir ]] || continue
  # Only bootstrap if it looks like a Rails project (has Gemfile)
  [[ -f "$dir/Gemfile" ]] || continue
  bootstrap_project "$dir"
done

echo ""
echo "Done. Enter a project directory to activate its devShell."
