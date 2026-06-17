# Shared devenv Module — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a shared devenv module in `abstracts33d/nix-devshells` that every digITpro Rails repo imports, with all dev-environment hardening baked in, Tier-1 flake-check tests, and AMR-back migrated as the canary.

**Architecture:** `nix-devshells` gains the `devenv` flake input and exposes `outputs.devenvModules.rails` — a NixOS-style module declaring `options.digitpro.rails.*` and producing devenv `config`. Consumer repos add a `devenv.yaml` input + a small `devenv.nix` that imports the module and sets options. A committed fixture Rails app plus `flake check`s build each `rails-rubyXX` shell and smoke-test native-gem loading.

**Tech Stack:** Nix flakes, cachix/devenv, NixOS module system (`lib.mkOption`), Ruby/Bundler, foreman, GitHub Actions.

**Reference:** The design spec is `docs/specs/2026-06-17-shared-devenv-module-design.md`. The canonical internals are lifted from the working `AMR-back/devenv.nix`.

---

## File Structure

In `abstracts33d/nix-devshells`:
- `flake.nix` — *modify*: add `devenv` input; expose `devenvModules.rails`; add `checks`.
- `modules/rails.nix` — *create*: the devenv module (options + config).
- `tests/fixture/Gemfile` — *create*: minimal app exercising native gems (`ruby-vips`, `pg`, `nokogiri`).
- `tests/fixture/Gemfile.lock` — *create*: resolved lock for the fixture.
- `tests/smoke.rb` — *create*: smoke script (`require` native libs).
- `.github/workflows/flake-check.yml` — *create*: CI running `nix flake check`.

In `digITpro/AMR-back` (canary):
- `devenv.yaml` — *create*: declares the `digitpro-devshells` input.
- `devenv.nix` — *replace*: ~8-line consumer config.
- `flake.nix`, `flake.lock` — *delete*: superseded by the shared module.

---

## Task 1: Pin the devenv module-composition mechanism

**Why:** devenv's exact syntax for importing a module from a remote flake input is version-specific. Establish it from docs before writing consumer files, so later tasks use the correct `devenv.yaml`/`imports` form.

**Files:** none (research + a scratch verification repo).

- [ ] **Step 1: Read the devenv composition docs**

Fetch and read the "Inputs" and "Composing using imports" pages of the devenv docs (https://devenv.sh/inputs/ and https://devenv.sh/composing-using-imports/). Use the `claude-code-guide` agent or WebFetch. Confirm: how a flake input exposes a module, and the `devenv.yaml` `inputs:` + `imports:` syntax a consumer uses to pull it in.

- [ ] **Step 2: Prove it with a throwaway consumer**

Create `/tmp/devenv-import-spike/` with a `devenv.yaml` referencing a local copy of `nix-devshells` exporting a trivial module that sets one env var, and a `devenv.nix` importing it. Run `direnv allow` / `nix develop --impure -c env | grep SPIKE_OK`.
Expected: the env var set by the imported module is present.

- [ ] **Step 3: Record the canonical snippets**

Write the confirmed `devenv.yaml` and `devenv.nix` import lines into `docs/specs/2026-06-17-shared-devenv-module-design.md` under "Architecture" (replace the illustrative snippet). Commit.

```bash
git add docs/specs/2026-06-17-shared-devenv-module-design.md
git commit -m "docs: pin devenv module-composition syntax in spec"
```

---

## Task 2: Add the devenv input and module skeleton

**Files:**
- Modify: `flake.nix` (inputs + outputs)
- Create: `modules/rails.nix`

- [ ] **Step 1: Add the devenv input to `flake.nix`**

In `flake.nix` `inputs`, add:

```nix
    devenv.url = "github:cachix/devenv";
```

- [ ] **Step 2: Create the module skeleton `modules/rails.nix`**

```nix
{ lib, pkgs, config, ... }:
let
  cfg = config.digitpro.rails;
in {
  options.digitpro.rails = {
    ruby = lib.mkOption {
      type = lib.types.enum [ "2.7" "3.2" "3.3" "3.4" ];
      description = "Ruby version; maps to an ABI-correct nixpkgs.";
    };
    node = {
      enable = lib.mkOption { type = lib.types.bool; default = true; };
      version = lib.mkOption { type = lib.types.enum [ "22" "24" ]; default = "22"; };
      packageManager = lib.mkOption { type = lib.types.enum [ "yarn" "npm" ]; default = "yarn"; };
    };
    postgres = {
      enable = lib.mkOption { type = lib.types.bool; default = false; };
      package = lib.mkOption { type = lib.types.package; default = pkgs.postgresql; };
    };
    redis.enable = lib.mkOption { type = lib.types.bool; default = false; };
    devenvUp.enable = lib.mkOption { type = lib.types.bool; default = false; };
    extraPackages = lib.mkOption { type = lib.types.listOf lib.types.package; default = []; };
    extraEnv = lib.mkOption { type = lib.types.attrsOf lib.types.str; default = {}; };
  };

  config = {
    # filled in by later tasks
  };
}
```

- [ ] **Step 3: Expose the module from `flake.nix` outputs**

In the `outputs` attrset add:

```nix
    devenvModules.rails = import ./modules/rails.nix;
```

- [ ] **Step 4: Verify the flake evaluates**

Run: `nix flake show 2>&1 | grep -i devenvModules`
Expected: `devenvModules` appears (and no eval error).

- [ ] **Step 5: Commit**

```bash
git add flake.nix modules/rails.nix
git commit -m "feat: scaffold digitpro.rails devenv module + options"
```

---

## Task 3: Fixture app + first failing smoke check

**Files:**
- Create: `tests/fixture/Gemfile`, `tests/fixture/Gemfile.lock`, `tests/smoke.rb`
- Modify: `flake.nix` (add `checks`)

- [ ] **Step 1: Create the fixture `tests/fixture/Gemfile`**

```ruby
source "https://rubygems.org"
ruby "3.4.1"

gem "nokogiri"   # native, uses libxml2
gem "pg"         # native, needs pg_config + libpq
gem "ruby-vips"  # FFI dlopen of libvips.so.42 at require time
```

- [ ] **Step 2: Generate the lock inside a shell that has the toolchain**

Run: `cd tests/fixture && nix develop ..#rails-ruby34 -c bundle lock`
Expected: `Gemfile.lock` created. Commit it alongside the Gemfile (it pins the smoke test).

- [ ] **Step 3: Create `tests/smoke.rb`**

```ruby
# Smoke test: every native dependency the shells must support loads cleanly.
require "nokogiri"
require "pg"
require "vips"
puts "SMOKE_OK ruby=#{RUBY_VERSION} vips=#{Vips::VERSION_STRING rescue 'n/a'}"
```

- [ ] **Step 4: Add a check to `flake.nix` that builds the fixture shell and runs the smoke test**

In `outputs`, under `checks = forAllSystems (system: { ... })`, add (using the existing `mkRailsShellFor` only for native libs; the check runs `bundle install` then the smoke script):

```nix
      smoke-ruby34 = pkgs.runCommand "smoke-ruby34" {
        buildInputs = [ (mkRailsShellFor system { ruby = "3.4"; }).buildInputs ];
      } ''
        echo "placeholder — replaced in Task 11"; touch $out
      '';
```

(The real per-version checks land in Task 11; this one exists now only to drive the module implementation.)

- [ ] **Step 5: Run the smoke locally against the *fixture* to confirm it FAILS without the module**

Run: `cd tests/fixture && nix develop ..#rails-ruby34 -c ruby ../smoke.rb`
Expected: FAIL — `LoadError: Could not open library 'libvips.so.42'` (the plain `rails-ruby34` shell built from `mkShell` lacks `LD_LIBRARY_PATH`). This is the exact regression the module must fix.

- [ ] **Step 6: Commit**

```bash
git add tests/fixture/Gemfile tests/fixture/Gemfile.lock tests/smoke.rb flake.nix
git commit -m "test: add native-gem fixture + smoke script (currently failing)"
```

---

## Task 4: Implement core module config (languages, packages, base env)

**Files:** Modify `modules/rails.nix` (`config` block)

- [ ] **Step 1: Map the `ruby` option to a package and write the `config`**

Replace the empty `config` with:

```nix
  config = let
    rubyPkg = {
      "2.7" = pkgs.ruby_2_7;
      "3.2" = pkgs.ruby_3_2;
      "3.3" = pkgs.ruby_3_3;
      "3.4" = pkgs.ruby_3_4;
    }.${cfg.ruby};
    nodePkg = { "22" = pkgs.nodejs_22; "24" = pkgs.nodejs_24; }.${cfg.node.version};
  in {
    languages.ruby = {
      enable = true;
      package = rubyPkg;
      bundler.enable = false;  # use Ruby's bundled bundler (see spec: avoids rubygems integrity conflict)
    };

    languages.javascript = lib.mkIf cfg.node.enable {
      enable = true;
      package = nodePkg;
      yarn.enable = cfg.node.packageManager == "yarn";
      npm.enable = cfg.node.packageManager == "npm";
    };

    packages = with pkgs; [
      cfg.postgres.package
      libyaml libffi zlib readline openssl libxml2 libxslt
      imagemagick vips pkg-config gnumake gcc
    ] ++ cfg.extraPackages;

    env = {
      PGHOST = "/run/postgresql";
      DATABASE_URL = "postgresql:///";
      BUNDLE_BUILD__PG = "--with-pg-config=${lib.getExe' cfg.postgres.package "pg_config"}";
      BUNDLE_BUILD__NOKOGIRI = "--use-system-libraries";
      DISABLE_SPRING = "1";
    } // cfg.extraEnv;
  };
```

(`PGHOST` is overridden in Task 9 when managed Postgres is enabled.)

- [ ] **Step 2: Verify the module evaluates with a sample config**

Run: `nix eval --impure --expr 'let f = builtins.getFlake (toString ./.); in "ok"' 2>&1 | tail -1`
Expected: `"ok"` (no eval error in the flake).

- [ ] **Step 3: Commit**

```bash
git add modules/rails.nix
git commit -m "feat: core module config (ruby/node/packages/env)"
```

---

## Task 5: Bundler strategy + lockfile shadow (enterShell)

**Files:** Modify `modules/rails.nix`

- [ ] **Step 1: Add the Gemfile/lockfile shadow to `config.enterShell`**

Add an `enterShell` to the `config` (lifted from the working AMR-back `devenv.nix`):

```nix
    enterShell = ''
      # Gemfile shadow — strip the `ruby "X.Y.Z"` pin so bundler accepts the
      # nixpkgs patch version. Symlink the lockfile so `bundle install` writes
      # flow back to the canonical Gemfile.lock.
      if grep -q '^ruby "' Gemfile 2>/dev/null; then
        sed '/^ruby "/d' Gemfile > .Gemfile.nix
        ln -sf Gemfile.lock .Gemfile.nix.lock
        export BUNDLE_GEMFILE="$PWD/.Gemfile.nix"
      fi
    '';
```

- [ ] **Step 2: Verify in the fixture**

Run: `cd tests/fixture && nix develop ..#rails-ruby34 -c true` (shell still builds; this just checks no syntax error in the hook once wired — full wiring is via the module, exercised in Task 11).
Expected: exit 0.

- [ ] **Step 3: Commit**

```bash
git add modules/rails.nix
git commit -m "feat: bundler strategy + lockfile shadow in enterShell"
```

---

## Task 6: Stale-gem guard + versioned `.gems` layout

**Files:** Modify `modules/rails.nix` (`enterShell`)

- [ ] **Step 1: Append the guard + layout to `enterShell`** (verbatim from AMR-back):

```nix
      # Stale-gem guard — wipe .gems when the Ruby store prefix changes, so
      # native extensions don't link to a garbage-collected libruby.
      ruby_prefix="$(ruby -e 'puts RbConfig::CONFIG["prefix"]')"
      ruby_stamp="$PWD/.gems/.ruby-prefix"
      if [ -d "$PWD/.gems" ] && [ -f "$ruby_stamp" ] && [ "$(cat "$ruby_stamp")" != "$ruby_prefix" ]; then
        echo "Ruby store path changed → wiping .gems (run 'bundle install' to rebuild)"
        rm -rf "$PWD/.gems"
      fi
      mkdir -p "$PWD/.gems"
      echo "$ruby_prefix" > "$ruby_stamp"

      # Local gems in a versioned subdir
      ruby_abi="$(ruby -e 'puts RbConfig::CONFIG["ruby_version"]')"
      export BUNDLE_PATH="$PWD/.gems"
      export GEM_HOME="$PWD/.gems/ruby/$ruby_abi"
      export GEM_PATH="$PWD/.gems/ruby/$ruby_abi"
      export PATH="$PWD/.gems/ruby/$ruby_abi/bin:$PWD/bin:$PATH"
```

- [ ] **Step 2: Verify the fixture installs gems into the versioned path**

Run: `cd tests/fixture && nix develop ..#rails-ruby34 -c bash -c 'bundle install && ls .gems/ruby/*/gems | grep ruby-vips'`
Expected: `ruby-vips-...` listed under `.gems/ruby/3.4.0/gems`.

- [ ] **Step 3: Commit**

```bash
git add modules/rails.nix
git commit -m "feat: stale-gem guard + versioned .gems layout"
```

---

## Task 7: vips `LD_LIBRARY_PATH` + Darwin override

**Files:** Modify `modules/rails.nix`

- [ ] **Step 1: Add the Darwin-aware vips package in the `config let` block**

```nix
    vips =
      if pkgs.stdenv.isDarwin
      then (pkgs.vips.override { matio = null; withIntrospection = false; }).overrideAttrs
             (prev: { mesonFlags = (prev.mesonFlags or []) ++ ["-Dmatio=disabled"]; })
      else pkgs.vips;
```

- [ ] **Step 2: Use `vips` in `packages` and set `LD_LIBRARY_PATH` in `env`**

Replace `vips` in the packages list with the local `vips` binding, and add to `env`:

```nix
      LD_LIBRARY_PATH = lib.makeLibraryPath [ vips pkgs.imagemagick ];
```

- [ ] **Step 3: Verify the smoke script now PASSES via the module**

Run: `cd tests/fixture && nix develop ..#rails-ruby34 -c true` first to ensure build; then run the module-driven check added in Task 11. For now, sanity-check the lib is exported: `cd tests/fixture && nix develop ..#rails-ruby34 -c bash -c 'echo $LD_LIBRARY_PATH | tr : "\n" | grep -i vips'`
Expected: a `…/vips-*/lib` path. (Full `require "vips"` pass is asserted in Task 11.)

- [ ] **Step 4: Commit**

```bash
git add modules/rails.nix
git commit -m "feat: vips on LD_LIBRARY_PATH + darwin override"
```

---

## Task 8: `.ruby-version` mismatch warning

**Files:** Modify `modules/rails.nix` (`enterShell`)

- [ ] **Step 1: Append the warning to `enterShell`**

```nix
      # Warn (don't block) when the configured ruby ≠ .ruby-version major.minor
      if [ -f .ruby-version ]; then
        rv="$(tr -d 'ruby- \n' < .ruby-version | cut -d. -f1,2)"
        if [ -n "$rv" ] && [ "$rv" != "${cfg.ruby}" ]; then
          printf '\033[33m⚠ devenv: configured ruby ${cfg.ruby} ≠ .ruby-version (%s). Update digitpro.rails.ruby or .ruby-version.\033[0m\n' "$rv"
        fi
      fi
      echo "Rails devenv: Ruby $(ruby --version | cut -d' ' -f2) | Node $(node --version 2>/dev/null || echo n/a)"
```

- [ ] **Step 2: Verify the warning fires on mismatch**

In `tests/fixture`, create `.ruby-version` with `3.3.0`, then: `nix develop ..#... ` via a module config with `ruby = "3.4"` (use the dev consumer from Task 11). Expected: yellow warning printed. Remove the temp `.ruby-version` after.

- [ ] **Step 3: Commit**

```bash
git add modules/rails.nix
git commit -m "feat: warn on configured-ruby vs .ruby-version mismatch"
```

---

## Task 9: Opt-in managed Postgres / Redis

**Files:** Modify `modules/rails.nix`

- [ ] **Step 1: Verify devenv's Postgres socket/env wiring**

Read https://devenv.sh/services/ (or via `claude-code-guide`) to confirm which env var devenv exports for the managed socket and the default socket dir.
Expected output of the step: the exact `services.postgres` options and the socket path to put in `DATABASE_URL`/`PGHOST`.

- [ ] **Step 2: Add the services config with `lib.mkMerge`**

```nix
    services.postgres = lib.mkIf cfg.postgres.enable {
      enable = true;
      package = cfg.postgres.package;
      listen_addresses = "";  # unix socket only
    };
    services.redis.enable = cfg.redis.enable;
```

And override the DB env only when managed Postgres is on (devenv places the socket under the devenv state dir; use the path confirmed in Step 1):

```nix
    env = lib.mkMerge [
      { /* base env from Task 4 */ }
      (lib.mkIf cfg.postgres.enable {
        PGHOST = "$PGHOST";          # set by devenv to the managed socket dir
        DATABASE_URL = "postgresql:///";
      })
      (lib.mkIf cfg.redis.enable { REDIS_URL = "redis://localhost:6379"; })
    ];
```

- [ ] **Step 3: Verify Postgres starts under `devenv up` in the fixture**

Run: `cd tests/fixture && nix develop ..#... -c devenv up &` then `psql "postgresql:///" -c 'select 1'`.
Expected: `1`. Stop with `devenv processes stop` / kill.

- [ ] **Step 4: Commit**

```bash
git add modules/rails.nix
git commit -m "feat: opt-in managed postgres/redis with socket env wiring"
```

---

## Task 10: `devenv up` foreman wrapper

**Files:** Modify `modules/rails.nix`

- [ ] **Step 1: Add the opt-in process that execs the Procfile**

```nix
    processes = lib.mkIf cfg.devenvUp.enable {
      app.exec = "exec foreman start -f Procfile.dev";
    };
    packages = [ /* …existing… */ ] ++ lib.optional cfg.devenvUp.enable pkgs.foreman;
```

(Merge the `lib.optional` into the existing packages list rather than redefining it.)

- [ ] **Step 2: Verify `devenv up` runs the Procfile when enabled**

In a consumer with `devenvUp.enable = true` and a `Procfile.dev`, run `devenv up` and confirm the `app` process appears and the web process boots. Expected: Puma "Listening on".

- [ ] **Step 3: Commit**

```bash
git add modules/rails.nix
git commit -m "feat: opt-in devenv up wrapper around Procfile.dev"
```

---

## Task 11: Real flake checks across all Ruby versions

**Files:** Modify `flake.nix`

- [ ] **Step 1: Replace the placeholder check with module-driven smoke checks**

For each version in `["3.2" "3.3" "3.4"]` (2.7 added once Task 12 confirms support), build a devenv shell from the module with that `ruby` and run `bundle install` + `tests/smoke.rb` against `tests/fixture`. Add to `checks`:

```nix
      smoke = pkgs.runCommand "smoke-rails-shells" { } ''
        set -e
        for v in 3.2 3.3 3.4; do
          echo "== ruby $v =="
          # build the module shell for $v, cd into a copy of tests/fixture,
          # run: bundle install --quiet && ruby ../smoke.rb | grep SMOKE_OK
        done
        touch $out
      '';
```

Implement the loop body using the devenv `mkShell`/`nix develop` invocation confirmed in Task 1. The check must `grep SMOKE_OK` and fail otherwise.

- [ ] **Step 2: Run the full check suite**

Run: `nix flake check -L 2>&1 | tail -20`
Expected: all `smoke` checks pass; output contains `SMOKE_OK ruby=3.4`.

- [ ] **Step 3: Add CI workflow `.github/workflows/flake-check.yml`**

```yaml
name: flake-check
on: [push, pull_request]
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: cachix/install-nix-action@v27
        with:
          extra_nix_config: |
            experimental-features = nix-command flakes
      - run: nix flake check -L
```

- [ ] **Step 4: Commit**

```bash
git add flake.nix .github/workflows/flake-check.yml
git commit -m "test: flake-check smoke tests across ruby shells + CI"
```

---

## Task 12: Canary migration — AMR-back

**Files (in `digITpro/AMR-back`):**
- Create: `devenv.yaml`, new `devenv.nix`
- Delete: `flake.nix`, `flake.lock`

- [ ] **Step 1: Branch**

```bash
cd /home/s33d/dev/clients/digitpro/AMR-back
git checkout -b modernize/shared-devenv
```

- [ ] **Step 2: Create `devenv.yaml`** (using the syntax pinned in Task 1)

```yaml
inputs:
  digitpro-devshells:
    url: github:abstracts33d/nix-devshells
imports:
  - digitpro-devshells
```

- [ ] **Step 3: Replace `devenv.nix` with the consumer config**

```nix
{ ... }: {
  digitpro.rails = {
    ruby = "3.4";
    postgres.enable = true;
  };
}
```

- [ ] **Step 4: Remove the bespoke flake and reset gems**

```bash
git rm flake.nix flake.lock
rm -rf .gems
```

- [ ] **Step 5: Verify boot in the new shell (the regression gate)**

```bash
direnv reload
bundle install
bin/rails runner 'puts "BOOT_OK " + Rails.version'
```
Expected: `BOOT_OK 8.x` with no `libvips`/native errors.

- [ ] **Step 6: Run the real suite in-shell**

Run: `bundle exec rspec --fail-fast 2>&1 | tail -5`
Expected: suite runs (green, or only pre-existing unrelated failures — compare to a baseline run on `main`).

- [ ] **Step 7: Commit**

```bash
git add devenv.yaml devenv.nix
git commit -m "chore: adopt shared digitpro devenv module"
```

---

## Task 13: Roll out to remaining repos (templated repeat of Task 12)

For each repo, repeat Task 12 Steps 1–7 with the repo's row from the spec's per-repo matrix. Migrate one, fully verify (boot + suite), commit, then proceed to the next. Do **not** batch.

- [ ] **vconfig** — `digitpro.rails = { ruby = "3.4"; postgres.enable = true; };`
- [ ] **topboard** — `{ ruby = "3.2"; postgres = { enable = true; package = pkgs.postgresql_16; }; };` (consumer needs `{ pkgs, ... }:` to reference `pkgs.postgresql_16`)
- [ ] **isfm** — `{ ruby = "3.4"; node.version = "24"; postgres.enable = true; };`
- [ ] **boardpilot** — `{ ruby = "3.2"; postgres.enable = true; };` (also removes the old central `.envrc` `use flake #rails-ruby32` line)
- [ ] **logic** — `{ ruby = "2.7"; postgres.enable = true; };` **best-effort.** If `bundle install`/boot fails on the bundler strategy, add the `ruby == "2.7"` pinned-bundler branch to `modules/rails.nix` (Task 5) and add `2.7` to the Task 11 check matrix; if still failing, leave logic on the old central shell and note it.

Set `redis.enable = true` for any repo whose Gemfile includes `redis`/`sidekiq` (grep the Gemfile during its migration).

---

## Self-Review

**Spec coverage:** module export (Task 2) ✓; option surface (Task 2) ✓; bundler strategy (Task 5) ✓; stale-gem guard + layout (Task 6) ✓; vips + Darwin (Task 7) ✓; ruby-version warning (Task 8) ✓; services (Task 9) ✓; devenv-up wrapper (Task 10) ✓; Tier-1 tests + CI (Tasks 3, 11) ✓; canary + rollout incl. 2.7 fallback (Tasks 12, 13) ✓. Non-goals (prod image, Tier-2) correctly excluded.

**Known verification dependencies (not placeholders — explicit spikes):** Task 1 pins the devenv import syntax; Task 9 Step 1 pins devenv's Postgres socket env var. Both are documented features whose exact current syntax must be read from devenv docs before the dependent code is finalized; later tasks consume their confirmed output.

**Type/name consistency:** option names (`digitpro.rails.{ruby,node.*,postgres.*,redis.enable,devenvUp.enable,extraPackages,extraEnv}`) are used identically in Tasks 2, 4, 7, 9, 10, 12, 13. `vips` binding defined in Task 7 and referenced in `packages`/`env`. `mkRailsShellFor` reused from the existing flake.
