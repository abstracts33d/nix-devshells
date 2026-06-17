# Shared devenv module for digITpro Rails dev environments

- **Date:** 2026-06-17
- **Status:** Approved design, pending implementation plan
- **Repo:** `abstracts33d/nix-devshells` (module) + digITpro Rails repos (consumers)

## Problem

digITpro's Rails repos run three different Nix dev-environment mechanisms:

1. **Centralized plain `mkShell`** via `use flake "github:abstracts33d/nix-devshells#rails-rubyXX"` — AMR-Archives (2.6), logic (2.7), boardpilot (3.2).
2. **Local `flake.nix` + `devenv.nix`** (`use flake . --impure`) — AMR-back, AMR-front, isfm, topboard, vconfig. Each hand-rolled.
3. **No Nix** — claude-dev, ecos.

The five local `devenv.nix` files diverge across seven concerns: bundler strategy (four variants), lockfile shadowing (none / copy / symlink), stale-gem guard (present in 3, missing in isfm), vips handling (only AMR-back), Postgres pin, Node version/package-manager, and `.gems` layout. Because each fix was discovered per-repo, fixes do not propagate.

This caused a real outage: **vconfig's server stopped booting** because it gained `ruby-vips`/`image_processing` but its `devenv.nix` never got the libvips `LD_LIBRARY_PATH` fix that AMR-back already had. `ruby-vips` `dlopen`s `libvips.so.42` via FFI against the system library path, which does not exist on NixOS, so boot aborted in `Bundler.require`.

## Goals

- One **shared devenv module** as the single source of truth; consumer repos shrink to a small typed config.
- Bake all hardening into the module so a fix in one place reaches every repo.
- **Opt-in managed services** (Postgres/Redis) to remove the system-Postgres (`/run/postgresql`) dependency and unblock macOS developers.
- **Tier-1 regression tests** in the module repo now.
- Migrate the active Rails repos.

## Non-goals

- Production runtime. Apps deploy via Kamal → Docker; the Dockerfile remains the prod artifact. Dev/prod parity via Nix-built images (`dockerTools.buildLayeredImage` / `devenv container`) is a **future POC**, out of scope here.
- **Tier-2** cross-repo automation (consumer CI-in-shell + pinned-input bump PRs) — planned, but later.
- AMR-front (Astro/Node, no Ruby), claude-dev, ecos. `logic` (Ruby 2.7) is best-effort and may be excluded if the canonical bundler strategy does not work on 2.7.

## Architecture

**Module-exposure mechanism (confirmed empirically — devenv 2.1.3).** devenv does *not* consume modules via a `devenvModules.rails` flake output. A reusable module is just a `devenv.nix` (or any `.nix` module file) **at a path inside the input repo**; consumers reference it by `<input-name>/<path>`. So `nix-devshells` exposes the module by committing it at a stable path — `rails/devenv.nix` — and declares the `devenv` input itself so the module can use devenv options. (The flake's existing `lib.mkRailsShell` and `rails-rubyXX` plain shells stay for any non-migrated consumer; they are unrelated to devenv module exposure.)

A consumer repo contains:

- `devenv.yaml` declaring the `digitpro-devshells` input (pinned to a commit/tag) and importing the module by input-relative path. The imported input is referenced as a non-flake source (`flake: false`); `imports:` entries are *not* flake outputs but paths within the input:

  ```yaml
  inputs:
    nixpkgs:
      url: github:cachix/devenv-nixpkgs/rolling
    digitpro-devshells:
      url: github:abstracts33d/nix-devshells/<pinned-rev>
      flake: false
  imports:
    - digitpro-devshells/rails
  ```

- `devenv.nix` — sets *only* the per-repo config; the import is declared in `devenv.yaml`, not here:

  ```nix
  { ... }: {
    digitpro.rails = {
      ruby = "3.2";
      postgres.enable = true;
    };
  }
  ```

- `.envrc`: `use flake . --impure` (devenv requires impurity).

  Note: with the flakeless `devenv` CLI the above `devenv.yaml`/`devenv.nix` are sufficient. With the flake-integration path (`nix develop`/`use flake`), the consumer's `flake.nix` instead lists the module under `devenv.lib.mkShell { modules = [ (digitpro-devshells + "/rails/devenv.nix") ]; }` with `digitpro-devshells.flake = false;` as an input. Both were verified to set module env (proof: `SPIKE_OK`).

Updating the shared module updates every consumer on the next `direnv reload` (subject to each repo's pinned input — see Testing).

## Module interface — `digitpro.rails.*`

| Option | Type | Default | Notes |
|--------|------|---------|-------|
| `ruby` | enum `"2.7"`/`"3.2"`/`"3.3"`/`"3.4"` | *(required)* | Maps to the ABI-correct nixpkgs (reuses existing `rubyEnv` pinning) |
| `node.enable` | bool | `true` | |
| `node.version` | enum `"22"`/`"24"` | `"22"` | isfm → `"24"` |
| `node.packageManager` | enum `"yarn"`/`"npm"` | `"yarn"` | |
| `postgres.enable` | bool | `false` | opt-in |
| `postgres.package` | package | `pkgs.postgresql` | topboard → `postgresql_16` |
| `redis.enable` | bool | `false` | opt-in; set per app based on actual Redis use |
| `devenvUp.enable` | bool | `false` | opt-in `devenv up` that execs `Procfile.dev` (see below) |
| `extraPackages` | list | `[]` | escape hatch |
| `extraEnv` | attrs | `{}` | escape hatch |

## Always-on internals (not per-repo knobs)

1. **Bundler strategy (canonical = AMR-back's):** `languages.ruby.bundler.enable = false` (use Ruby's bundled bundler, avoiding the rubygems integrity conflict the other repos worked around with version-pinning + purging); shadow `Gemfile` strips the `ruby "…"` pin into `.Gemfile.nix` with `BUNDLE_GEMFILE` set; **symlink** `Gemfile.lock` → `.Gemfile.nix.lock` so `bundle install` writes flow back to the canonical lockfile. If Ruby 2.7 cannot use this, the module branches on `ruby == "2.7"` to the pinned-bundler variant.
2. **Stale-gem guard:** wipe `.gems` when the Ruby store prefix changes (records a stamp at `.gems/.ruby-prefix`).
3. **vips (always included):** add `vips` to packages and set `LD_LIBRARY_PATH = lib.makeLibraryPath [vips imagemagick]`. On Darwin, override vips with `matio = null; withIntrospection = false;`. Included unconditionally because the cost is low and absence is the exact failure mode that broke vconfig.
4. **`.gems` layout:** versioned `ruby/$abi` subdir; `BUNDLE_PATH`/`GEM_HOME`/`GEM_PATH`/`PATH` point there.
5. **`.ruby-version` mismatch warning:** at shell entry, read `.ruby-version`, normalize to `major.minor` (handles `3.2.2`, `ruby-3.2.2`, trailing newline), compare to `digitpro.rails.ruby`, print a yellow warning on mismatch. Runtime check only — never blocks the shell.

## Services

Both opt-in. When `postgres.enable`, the module turns on `services.postgres` and points `DATABASE_URL`/`PGHOST` at the devenv-managed socket under `.devenv/`, replacing `/run/postgresql`. When `redis.enable`, it turns on `services.redis` and sets `REDIS_URL`.

## Process management

`Procfile.dev` remains the team's canonical process definition; `bin/dev` (foreman/overmind) is unchanged. When `devenvUp.enable`, the module defines a single devenv process that execs `foreman start -f Procfile.dev`, so `devenv up` works for developers who want it without creating a second, drift-prone process definition. Native per-process `devenv processes` can replace the wrapper later if desired.

## Per-repo configuration matrix

| Repo | `ruby` | `node` | `postgres.package` | Notes |
|------|--------|--------|--------------------|-------|
| AMR-back | 3.4 | 22/yarn | default | canary; already runs the canonical pattern |
| vconfig | 3.4 | 22/yarn | default | libvips fix folds into module |
| topboard | 3.2 | 22/yarn | `postgresql_16` | pg gem 1.5.4 needs libpq ≤ 16 |
| isfm | 3.4 | 24/yarn | default | |
| boardpilot | 3.2 | 22/yarn | default | currently on the central plain shell |
| logic | 2.7 | (legacy) | default | best-effort; exclude if 2.7 bundler fails |

`redis.enable` is set per repo at migration time based on whether the app actually uses Redis.

## Testing

**Tier 1 (now):** the module repo commits a minimal fixture Rails app (a `Gemfile` with `ruby-vips`, `pg`, `nokogiri`) and exposes `checks.<system>.*` that build each `rails-rubyXX` shell and run a smoke test: `bundle install`, `ruby -e "require 'vips'"`, `pg` load. CI runs `nix flake check`. Catches the libvips/native-extension class of breakage in seconds without any real app.

**Tier 2 (later):** each consumer pins the module input and runs its own CI suite inside the shell (`nix develop -c bundle exec rspec`); a workflow opens "bump shared flake" PRs across the repos so the real app suites are the regression gate. Tracked outside this spec.

## Migration plan

1. Build the `rails/devenv.nix` module in `nix-devshells` (committed at that path, imported by consumers as `digitpro-devshells/rails`) with all always-on internals.
2. Add Tier-1 `flake check` + fixture app.
3. **Canary:** migrate AMR-back (lowest risk — already runs the canonical pattern); verify boot + suite in-shell.
4. Roll out: vconfig, topboard (`postgresql_16`), isfm (`node 24`), boardpilot.
5. logic (Ruby 2.7) last, best-effort.
6. Each migrated repo deletes its bespoke `flake.nix`/`devenv.nix`, replaced by the ~8-line consumer `devenv.nix` + `devenv.yaml`.

## Risks & mitigations

- **Ruby 2.7 + canonical bundler:** may fail; mitigation is the `ruby == "2.7"` branch, else exclude logic.
- **Darwin vips override forces a source build:** slower first build; mitigated by a binary cache.
- **Binary cache not currently usable:** dev shells log `ignoring untrusted substituter 'devenv.cachix.org' … you are not a trusted user`. Add the user to `trusted-users` in `nix.conf` (and ideally run an org Cachix/attic cache CI pushes to). Independent quick win.
- **`--impure` reduces reproducibility:** accepted trade-off for devenv services/processes.
- **First migration changes `.gems` layout:** triggers one `.gems` wipe + `bundle install` per repo.

## Rollback

Each repo migration is a branch/PR; reverting restores the previous `flake.nix`/`devenv.nix`. The module repo keeps the plain `rails-rubyXX` shells, so a repo can fall back to the old centralized mechanism without code changes.
