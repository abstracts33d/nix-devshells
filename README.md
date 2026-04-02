# nix-devshells

Reproducible Rails development environments powered by Nix. Works on Linux (x86_64, aarch64) and macOS (Intel, Apple Silicon).

Two approaches are available depending on your needs:

- **Centralized devShells** — shared, zero-config, all projects use the same environment
- **Per-project devenv** — each project owns its dependencies, services, and lock file

## Prerequisites

### Install Nix

If you don't have Nix installed yet:

```sh
# Linux or macOS — Determinate Nix Installer (recommended)
curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install

# Verify
nix --version
```

The Determinate installer enables flakes and the nix command by default. If you used the official installer, add to `~/.config/nix/nix.conf`:

```
experimental-features = nix-command flakes
```

#### `nix develop` vs `nix shell`

Both drop you into a shell with packages available, but they serve different purposes:

- **`nix develop`** — enters a devShell (development environment). Runs shell hooks, sets env vars, provides the full build environment. This is what you want for Rails projects.
- **`nix shell`** — adds packages to your PATH temporarily. No hooks, no env vars. Useful for quick one-off tools (`nix shell nixpkgs#jq` to get `jq` for a moment).

```sh
# Enter the Rails devShell (hooks run, env vars set, Gemfile shadow active)
nix develop github:abstracts33d/nix-devshells#rails-ruby34

# Just get Ruby on PATH temporarily (no env setup)
nix shell nixpkgs#ruby_3_4
```

#### Useful Nix commands

```sh
nix develop .#shell-name       # enter a devShell (without direnv)
nix shell nixpkgs#package      # quick temporary access to a package
nix flake update               # update all flake inputs to latest
nix flake lock --update-input nixpkgs  # update a single input
nix flake show                 # list all outputs of a flake
nix store gc                   # garbage collect unused store paths
nix profile list               # list packages installed via nix profile
```

### Install direnv + nix-direnv (recommended, not required)

direnv automatically loads the dev environment when you `cd` into a project. nix-direnv makes it fast by caching the evaluation.

If you prefer not to use direnv, you can always enter a shell manually:

```sh
# Centralized approach
nix develop github:abstracts33d/nix-devshells#rails-ruby34

# Per-project approach (from the project directory)
nix develop --impure
```

The rest of this section covers direnv setup for automatic shell loading.

#### NixOS

Managed declaratively. If you're using nix-devshells, direnv and nix-direnv are typically already configured in your system or Home Manager config.

#### macOS (nix-darwin)

Minimal `flake.nix` for a nix-darwin setup with direnv and nix-direnv:

```nix
{
  description = "macOS development machine";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    darwin.url = "github:LnL7/nix-darwin";
    darwin.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = {nixpkgs, darwin, ...}: {
    darwinConfigurations.my-mac = darwin.lib.darwinSystem {
      system = "aarch64-darwin"; # or "x86_64-darwin" for Intel
      modules = [
        ({pkgs, ...}: {
          # Nix settings
          nix.settings.experimental-features = ["nix-command" "flakes"];
          nixpkgs.hostPlatform = "aarch64-darwin";

          # System packages
          environment.systemPackages = with pkgs; [
            git
          ];

          # direnv + nix-direnv
          programs.direnv = {
            enable = true;
            nix-direnv.enable = true;
          };

          # Required by nix-darwin
          system.stateVersion = 6;
        })
      ];
    };
  };
}
```

Bootstrap nix-darwin (first time only):

```sh
# From the directory containing the flake.nix above:
nix run nix-darwin -- switch --flake .#my-mac
```

After that, rebuild with:

```sh
darwin-rebuild switch --flake .#my-mac
```

#### macOS (Homebrew, without nix-darwin)

```sh
brew install direnv
nix profile install nixpkgs#nix-direnv
```

Add the shell hook to your shell rc file:

```sh
# zsh (~/.zshrc)
eval "$(direnv hook zsh)"

# bash (~/.bashrc)
eval "$(direnv hook bash)"
```

Add nix-direnv integration to `~/.config/direnv/direnvrc`:

```sh
source $HOME/.nix-profile/share/nix-direnv/direnvrc
```

#### Linux (non-NixOS)

First, install Nix if you haven't already (see [Install Nix](#install-nix) above).

Then install direnv and nix-direnv via Nix:

```sh
nix profile install nixpkgs#direnv nixpkgs#nix-direnv
```

Alternatively, direnv is available in most distro package managers (nix-direnv still needs Nix):

```sh
# Ubuntu / Debian
sudo apt install direnv

# Fedora
sudo dnf install direnv

# Arch
sudo pacman -S direnv

# Then install nix-direnv via Nix
nix profile install nixpkgs#nix-direnv
```

Add to your shell rc file:

```sh
# zsh (~/.zshrc)
eval "$(direnv hook zsh)"

# bash (~/.bashrc)
eval "$(direnv hook bash)"
```

Add nix-direnv integration to `~/.config/direnv/direnvrc`:

```sh
source $HOME/.nix-profile/share/nix-direnv/direnvrc
```

#### Useful direnv commands

```sh
direnv allow               # authorize the .envrc in current directory
direnv deny                # revoke authorization
direnv reload              # force reload (usually automatic)
direnv status              # show current state and loaded .envrc path
```

---

## Approach 1: Centralized devShells

A single shared environment per Ruby version. Projects reference it via `.envrc` — no files to add to the project repo.

### Setup

Create a `.envrc` in your Rails project:

```sh
use flake "github:abstracts33d/nix-devshells#rails-ruby34"
```

Then allow it:

```sh
direnv allow
```

That's it. `cd` into the project and the environment loads automatically.

### Without direnv

You can also enter a shell manually:

```sh
nix develop github:abstracts33d/nix-devshells#rails-ruby34
```

This drops you into a shell with everything loaded. Exit with `exit` or `Ctrl-D`.

### Available shells

| Shell name | Ruby | nixpkgs channel |
|------------|------|-----------------|
| `rails-ruby34` (default) | 3.4 | unstable |
| `rails-ruby33` | 3.3 | unstable |
| `rails-ruby32` | 3.2 | 24.11 (stable) |
| `rails-ruby27` | 2.7 | 22.11 |
| `rails-ruby26` | 2.6 | 21.05 |

Each Ruby version uses the nixpkgs channel that ships it with an ABI-compatible GCC toolchain.

### Batch setup for multiple projects

```sh
./bootstrap-legacy.sh ~/dev/clients/myorg/project1 ~/dev/clients/myorg/project2
# or with a glob
./bootstrap-legacy.sh ~/dev/clients/myorg/*
```

The script reads `.ruby-version` from each project and writes the correct `.envrc`.

### What's included

- **Ruby** (version-pinned with ABI-compatible GCC)
- **Node.js 22** + Yarn (Node.js 14 for Ruby 2.6/2.7)
- **Native libs:** PostgreSQL, libyaml, libffi, zlib, readline, openssl, libxml2, libxslt, ImageMagick
- **Build tools:** pkg-config, gnumake, gcc, rustc, cargo
- **Dev tools:** overmind, pgcli, iredis
- **Environment:** GEM_HOME/GEM_PATH/BUNDLE_PATH set to `.gems/`, bundler build flags for pg and nokogiri
- **Gemfile shadow:** Strips `ruby "X.Y.Z"` from Gemfile so bundler accepts the nixpkgs patch version

### Pros

- **Zero config per project** — just a one-line `.envrc`, nothing committed to the project repo
- **Shared lock file** — all projects on the same Ruby version use the same pinned dependencies
- **Fast onboarding** — `bootstrap-legacy.sh` sets up all projects at once
- **No flake.nix in project** — no nix files to maintain per project

### Cons

- **No per-project customization** — all projects on the same Ruby share the same packages
- **No managed services** — relies on system-level PostgreSQL and Redis
- **Shared nixpkgs pin** — updating the lock file affects all projects at once
- **Extra packages need a fork** — adding a project-specific dependency means editing this repo

---

## Approach 2: Per-project devenv

Each project gets its own `flake.nix` + `devenv.nix` + `.envrc`. Full control over dependencies and lock file. Uses system-level PostgreSQL and Redis (same as the centralized approach).

> **Ruby 3.2+ only.** Legacy Ruby (2.6, 2.7) is incompatible with devenv — old nixpkgs package structures conflict with modern devenv evaluation. Use the centralized approach for legacy projects.

### Setup (new project)

```sh
cd ~/dev/myproject
nix flake init -t github:abstracts33d/nix-devshells#rails
```

This creates three files:

- `flake.nix` — devenv flake with nixpkgs-unstable
- `devenv.nix` — Rails config (Ruby, Node, packages, env vars)
- `.envrc` — `use flake . --impure`

Edit `devenv.nix` to set your Ruby version (default is `pkgs.ruby_3_4`), then:

```sh
# Files must be tracked by git for Nix to see them
git add flake.nix devenv.nix .envrc
direnv allow
```

### Without direnv

You can enter the devenv shell manually:

```sh
nix develop --impure
```

### Migrate existing project

```sh
./templates/rails/bootstrap.sh ~/dev/clients/myorg/project1
```

The script reads `.ruby-version` and patches the Ruby package. Only works for Ruby 3.2+ — legacy Ruby projects should use the centralized approach.

### What's included

Everything from the centralized approach, plus:

- **Per-project lock file** — `flake.lock` pins your exact dependency versions
- **Customizable** — edit `devenv.nix` to add packages, env vars, or devenv modules

### Files to track in git

| File | Git | Notes |
|------|-----|-------|
| `flake.nix` | Track | Devenv flake definition |
| `devenv.nix` | Track | Project-specific config |
| `.envrc` | Track | Direnv integration |
| `flake.lock` | Track | Pinned dependency versions |
| `.devenv/` | Ignore | Runtime state and caches |
| `.gems/` | Ignore | Local gem install directory |
| `.direnv/` | Ignore | Direnv cache |
| `.Gemfile.nix` | Ignore | Shadow Gemfile (auto-generated) |

### Pros

- **Full project isolation** — each project owns its dependencies and lock file
- **Customizable** — add packages, env vars, devenv modules directly in `devenv.nix`
- **Independent updates** — update one project's nixpkgs without affecting others
- **Portable** — project carries its entire dev environment, works on any Nix machine

### Cons

- **More files in project** — `flake.nix`, `devenv.nix`, `.envrc`, `flake.lock`
- **Slower first load** — devenv builds a full environment on first `cd` (cached after)
- **Larger closure** — each project has its own copy of packages in the nix store
- **`.gitignore` changes needed** — must unignore `flake.nix`, `.envrc` if previously ignored

---

## Which approach to use?

| Scenario | Recommendation |
|----------|---------------|
| Quick setup, many similar projects | Centralized |
| Project needs specific packages or services | Per-project devenv |
| CI/CD needs reproducible builds | Per-project devenv |
| Legacy Ruby (2.6, 2.7) | Centralized only (devenv incompatible) |
| Shared team environment | Per-project devenv (committed to repo) |
| Personal dev machine, fast iteration | Centralized |

Both approaches can coexist. Migrate projects one at a time using `templates/rails/bootstrap.sh`.

---

## Future evolution: per-project managed services

devenv supports managed services (PostgreSQL, Redis) per project via [process-compose](https://github.com/F1bonacc1/process-compose). This means each project gets its own database instance with data stored in `.devenv/state/` — no system-level postgres/redis needed.

To enable, add to `devenv.nix`:

```nix
services.postgres = {
  enable = true;
  listen_addresses = "127.0.0.1";
};
services.redis.enable = true;
```

Then start services with:

```sh
process-compose up       # foreground (TUI)
process-compose up -D    # background (detached)
process-compose down     # stop all
process-compose attach   # reattach TUI
```

This is useful for full project isolation (different postgres versions, CI environments, onboarding new developers without system setup). The current template uses system-level services for simplicity.

---

## Library API

For advanced usage, this flake exports `lib.mkRailsShellFor` and `lib.mkRailsShell` for building custom devShells in your own flake:

```nix
{
  inputs.nix-devshells.url = "github:abstracts33d/nix-devshells";

  outputs = {nix-devshells, ...}:
    nix-devshells.lib.mkRailsShell {
      ruby = "3.4";
      node = true;
      extraPackages = []; # add project-specific packages
      extraEnv = {};      # add project-specific env vars
    };
}
```

## Supported platforms

- `x86_64-linux`
- `aarch64-linux`
- `x86_64-darwin`
- `aarch64-darwin`
