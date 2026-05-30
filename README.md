# steam-multiuser

A shared Steam game library manager for multi-user Linux systems.

`steam-multiuser` lets several user accounts on one machine share a single copy
of installed Steam games — saving tens or hundreds of gigabytes of disk space —
while keeping each user's Proton prefixes, saves, shader caches, and Steam
configuration completely private. It sets up the permissions, group membership,
and per-login bind mounts required to make this work, and includes a thorough
diagnostic that detects and repairs a broken setup.

It is built and tested for **CachyOS** and other Arch-based distributions running
**KDE Plasma** with **SDDM** or **Plasma Login Manager**.

---

## Table of contents

- [Why this exists](#why-this-exists)
- [What it does](#what-it-does)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Usage](#usage)
- [Configuration](#configuration)
- [How it works (engineering deep dive)](#how-it-works-engineering-deep-dive)
- [Diagnostics](#diagnostics)
- [Troubleshooting](#troubleshooting)
- [Security model](#security-model)
- [Filesystem support](#filesystem-support)
- [Uninstalling](#uninstalling)
- [Contributing](#contributing)
- [License](#license)

---

## Why this exists

Steam stores each user's games under `~/.local/share/Steam/steamapps`. On a
shared computer — a family PC, a couch-gaming machine with several profiles, a
lab workstation — that means every account downloads and stores its own copy of
every game. Two accounts that both play a 100 GB title use 200 GB of disk for
one game.

Steam has no built-in concept of a shared library across user accounts. You
*can* point multiple users at a common library directory in Steam's settings,
but doing so naively breaks in two ways:

1. **Proton prefix collisions.** Proton stores each game's Windows-environment
   prefix in `steamapps/compatdata`. These are per-user by nature — they contain
   user-specific registry state, save data, and configuration. If two users
   share one `compatdata`, Wine refuses to start because the prefix is owned by
   the wrong user, and save data bleeds between accounts.

2. **Permission failures.** A library directory owned by one user is not
   writable by another, so Steam reports the path as inaccessible and refuses to
   install or update games there.

`steam-multiuser` solves both problems: game files are genuinely shared and
written once, while `compatdata` (and other per-user state) is transparently
swapped in per-user at login via a bind mount, so each account sees only its own
prefixes at the shared path.

---

## What it does

- **Shares** `steamapps/common` (game files), `steamapps/workshop`, and the
  Proton/Steam Runtime builds — the large, identical-across-users data.
- **Isolates** `steamapps/compatdata` (Proton prefixes), `shadercache`, and
  `userdata` per user via a per-login bind mount.
- **Manages** a dedicated `gamers` group, directory ownership, setgid
  inheritance, and the PAM session hook that performs the bind mount.
- **Onboards** new users with a single command, including registering the shared
  library in their Steam configuration automatically.
- **Migrates** existing per-user game installs into the shared library, with
  deduplication.
- **Relocates** the entire shared library to a new path (e.g. a newly added
  drive) safely, with verification before any source data is removed.
- **Diagnoses and repairs** every layer of the setup, idempotently.

---

## Requirements

- An Arch-based distribution (**CachyOS** is the primary target; plain Arch and
  other derivatives are expected to work).
- **systemd**.
- **KDE Plasma** session with **SDDM** or **Plasma Login Manager** as the display
  manager. Other desktops and display managers are untested.
- The following commands, all present in a standard Arch install:
  `bash`, `nsenter`, `findmnt`, `mountpoint`, `rsync`, `getent`, `loginctl`,
  `journalctl`, and the `pam_exec.so` PAM module (from the `pam` package).
- A filesystem for the shared library. **ZFS** and **ext4** are fully tested;
  **XFS** is expected to work; **btrfs**, **F2FS**, and **bcachefs** carry
  caveats noted by the diagnostic.

---

## Installation

### From the AUR (recommended)

```sh
# with an AUR helper such as paru or yay
paru -S steam-multiuser
```

### Manual

```sh
git clone https://github.com/benwhite1987/steam-multiuser.git
cd steam-multiuser
sudo install -Dm755 steam-multiuser.sh /usr/local/bin/steam-multiuser.sh
sudo install -Dm644 steam-multiuser.conf.example /etc/steam-multiuser.conf.example
```

The script can also self-install: run it once from your home directory and it
will copy itself to `/usr/local/bin/` and re-execute from there.

---

## Quick start

On a fresh setup with games already installed under each user's home directory:

```sh
# 1. Create the shared library on your chosen drive
sudo mkdir /steam-library

# 2. Run the setup — creates the gamers group, sets permissions,
#    installs the PAM session hook
sudo steam-multiuser.sh

# 3. Add each user to the shared library
sudo steam-multiuser.sh --add alice
sudo steam-multiuser.sh --add bob

# 4. Move existing games from home directories into the shared library
sudo steam-multiuser.sh --migrate

# 5. Each user logs out and back in, then opens Steam — the shared
#    library and all its games appear automatically
```

---

## Usage

| Command                          | Privilege | Description                                            |
| -------------------------------- | --------- | ------------------------------------------------------ |
| `steam-multiuser.sh`             | sudo      | Diagnose the setup and offer to fix any issues         |
| `steam-multiuser.sh --check`     | none      | Diagnose only — make no changes (runnable as any user) |
| `steam-multiuser.sh --add USER`  | sudo      | Onboard a new user to the shared library               |
| `steam-multiuser.sh --migrate`   | sudo      | Move all users' games into the shared library          |
| `steam-multiuser.sh --move PATH` | sudo      | Relocate the shared library to a new path              |
| `steam-multiuser.sh --help`      | none      | Detailed usage documentation                           |

Running the full fix mode without `sudo` automatically falls back to `--check`.

### Adding a user

The user must have logged in and launched Steam at least once so that their
`~/.local/share/Steam` directory exists. Then:

```sh
sudo steam-multiuser.sh --add USERNAME
```

This adds them to the `gamers` group, ensures the session mount hook covers them,
and registers the shared library in their `libraryfolders.vdf` so Steam sees the
games immediately. The user logs out and back in to activate the bind mount.

### Migrating existing installs

```sh
sudo steam-multiuser.sh --migrate
```

Close Steam on all accounts first. The migration copies game files into the
shared library, consolidates the appmanifest (`.acf`) files, deduplicates titles
that several users have installed, and sets each manifest's `StateFlags` to
`fully installed` so Steam does not needlessly re-verify (re-download) the games.
It uses `rsync`, so an interrupted migration leaves the original files intact.

### Relocating the library

If you add a second drive and want to move the library onto it:

```sh
sudo steam-multiuser.sh --move /mnt/gamedrive/steam
```

The move copies everything to the new location, verifies the copy, updates the
configuration file, regenerates the PAM mount script, rewrites every user's
`libraryfolders.vdf`, and only then removes the old location. The source is never
deleted until the copy is confirmed complete.

---

## Configuration

Defaults are defined at the top of the script and can be overridden without
editing it by creating `/etc/steam-multiuser.conf`:

```sh
# /etc/steam-multiuser.conf
LIBRARY=/mnt/gamedrive/steam      # shared library path (default: /steam-library)
GAMERS_GROUP=steam-users          # shared group name  (default: gamers)
```

All derived paths and every diagnostic message adapt automatically to these
values. Copy `steam-multiuser.conf.example` to `/etc/steam-multiuser.conf` to get
started.

---

## How it works (engineering deep dive)

The hard part of a shared Steam library is not sharing the game files — that is
just group permissions. The hard part is making `compatdata` **appear** shared
(at one path Steam knows about) while **being** private per user. This section
explains the full mechanism.

### The data model

Steam's `steamapps` directory contains a mix of shareable and per-user data:

| Path                                             | Nature                                          | Treatment               |
| ------------------------------------------------ | ----------------------------------------------- | ----------------------- |
| `steamapps/common/<game>/`                       | Game files, identical for all users             | **Shared**              |
| `steamapps/workshop/`                            | Workshop content                                | **Shared**              |
| `steamapps/common/Proton*`, `SteamLinuxRuntime*` | Runtimes, read-only at play time                | **Shared**              |
| `steamapps/appmanifest_*.acf`                    | Install records Steam reads to find games       | **Shared** (one copy)   |
| `steamapps/compatdata/`                          | Proton prefixes — per-user Windows environments | **Private**             |
| `steamapps/shadercache/`                         | Compiled shaders                                | **Private**             |
| `steamapps/userdata/`                            | Save data and per-user config                   | **Private**             |
| `~/.local/share/Steam/`                          | The Steam client itself                         | **Private** (untouched) |

The shared data lives once in the shared library (default `/steam-library`),
owned `root:gamers` with group-write and the setgid bit so new files created by
any group member stay group-owned. The private data stays in each user's home
directory.

### The core trick: a per-user bind mount at a shared path

Steam is configured to use `/steam-library` as a library folder. Inside it,
`/steam-library/steamapps/compatdata` must resolve to *the current user's*
prefixes — not a single shared directory. We achieve this with a **bind mount**
that is set up freshly at each login:

```
/home/alice/.local/share/Steam/steamapps/compatdata   (alice's real prefixes)
        │
        │  bind mount, created when alice logs in
        ▼
/steam-library/steamapps/compatdata                   (the shared path Steam sees)
```

When alice logs in, her private `compatdata` is bind-mounted onto the shared
path. When bob logs in, his is. Each user's Steam, reading
`/steam-library/steamapps/compatdata`, transparently sees only their own
prefixes. Wine is happy because the prefix it opens is genuinely owned by the
user running it. The shared path itself, when nothing is mounted, is a
locked-down empty directory (`root:root`, mode `000`) so it can never be written
to directly.

### Why a bind mount and not a symlink

A symlink would be global — it points one way for everyone. A bind mount is a
property of a **mount namespace**, so different processes can see different things
at the same path. That is exactly the per-user behavior we need. The remaining
question is *which* namespace to mount into so that the graphical session sees it.

### The namespace problem

This is the subtle part, and it drove the design.

A display manager like SDDM or Plasma Login Manager launches the user's graphical
session (KWin and everything under it). The session authenticates through PAM
using the `system-login` service. The natural place to hook a per-login action is
a PAM `session` module.

The obvious tool, `pam_namespace`, is designed for exactly this kind of
per-user directory polyinstantiation. **It does not work here**, and understanding
why is the key insight: `pam_namespace` *disassociates the session's mount
namespace from the parent namespace* — its whole purpose is to ensure that mounts
made for one session are invisible to others and to the rest of the system. But a
bind mount made inside that private, disassociated namespace is torn down when
the PAM session-setup process exits, **before** the long-lived graphical session
is fully established. The mount evaporates before Steam ever runs.

### The solution: `pam_exec` + `nsenter` into the root namespace

Instead of relying on `pam_namespace`, the tool installs a single PAM line in
`/etc/pam.d/system-login`:

```
session optional pam_exec.so stdout /usr/local/bin/steam-session-mount.sh
```

`pam_exec` runs an arbitrary script at session open, exporting `PAM_USER` and
`PAM_TYPE` into its environment. The script `steam-session-mount.sh`:

1. Exits immediately unless `PAM_TYPE` is `open_session`.

2. Exits unless the user is a member of the `gamers` group (no usernames are
   hardcoded — group membership is the entire filter).

3. Resolves the user's home directory and their private `compatdata`, creating it
   on first login if necessary.

4. Performs the bind mount — but **into the root (PID 1) mount namespace**, using:
   
   ```sh
   nsenter --mount=/proc/1/ns/mnt -- mount --bind "$SOURCE" "$TARGET"
   ```

`nsenter --mount=/proc/1/ns/mnt` enters init's mount namespace — the namespace
that the entire system, including the display-manager-launched graphical session,
ultimately shares. By doing the bind mount *there* rather than in a private
session namespace, the mount persists and is visible to the user's Steam process
for the life of the session. The script unmounts any stale bind at the target
first, so re-logins and user switches always land on the correct prefixes.

This is the crux of the whole design: the per-user view is achieved not by
isolating each session into its own namespace, but by mounting into the shared
root namespace at exactly the moment a given user owns the session.

> Earlier iterations of this project did configure `pam_namespace` alongside the
> `pam_exec` hook. Investigation showed it contributed nothing — the `nsenter`
> approach does all the work and needs no private namespace — so it was removed.
> The diagnostic detects and offers to clean up that configuration on systems set
> up with older versions.

### Appmanifests and avoiding re-downloads

Steam locates installed games by reading `appmanifest_*.acf` files **from the
library directory the manifest lives in**. For shared games to be visible, the
`.acf` files must live in the shared library's `steamapps/`, group-readable — not
in each user's home `steamapps`. A manifest in the home directory tells Steam to
look for the game there, where the files no longer exist, producing the classic
"missing game executable" error.

Each `.acf` also carries a `StateFlags` field. A value of `4` means "fully
installed"; other values tell Steam the game needs validating or updating. When
manifests are moved between library locations, Steam may reset this flag, causing
it to re-verify (and effectively re-download) the entire game on next launch. The
migration and onboarding paths therefore normalize `StateFlags` to `4` so that
moving a library does not trigger a mass re-download.

### Library registration

Rather than asking each user to add the shared library through Steam's Storage
settings, `--add` and `--move` edit the user's `libraryfolders.vdf` directly to
register the path, backing up the file first. Steam then sees the library — and
all its games — the next time it starts.

---

## Diagnostics

Running `steam-multiuser.sh` (or `--check` for a read-only pass) walks the entire
setup in ten stages and reports `[PASS]`, `[WARN]`, or `[FAIL]` for each, with an
optional fix prompt for anything that is wrong:

| Stage                    | Checks                                                       |
| ------------------------ | ------------------------------------------------------------ |
| 0. User discovery        | Enumerates real interactive accounts and their Steam status  |
| 1. Group membership      | Every gaming user is in the `gamers` group                   |
| 2. Library permissions   | Ownership, mode, and the `compatdata` lockdown               |
| 3. Setgid bits           | Group inheritance on shared directories                      |
| 4. PAM session hook      | `pam_exec` line and mount script; cleans up legacy config    |
| 5. Per-user Steam dirs   | Each user's private `compatdata`, shadercache, manifests     |
| 6. Active bind mount     | Whether the current session's bind mount is correct          |
| 7. Library configuration | `/steam-library` registered, manifests present, write access |
| 8. Cloud sync status     | Recent Steam cloud sync errors (all users when run as root)  |
| 9. Session mount status  | Login mount log; removes obsolete pre-release services       |

All fixes are idempotent — the script is safe to run repeatedly.

---

## Troubleshooting

**A game fails to launch with "missing game executable" pointing at a home
directory path.** The appmanifest is in the wrong place. Run
`sudo steam-multiuser.sh` and accept the appmanifest fixes, or `sudo steam-multiuser.sh
--migrate` if games were never consolidated.

**Steam reports the library path as inaccessible.** The user's session does not
yet have the `gamers` group active. Have them log out and back in, then reopen
Steam. `steam-multiuser.sh --check` reports per-user write access to confirm.

**The bind mount is not active after login.** Recover manually:

```sh
sudo /usr/local/bin/steam-compatdata-mount.sh USERNAME
```

**Inspect the login mount activity:**

```sh
journalctl -t steam-session-mount --since today
```

---

## Security model

- The shared library is owned `root:gamers`, mode `2775` (group-writable,
  setgid). Only members of the `gamers` group can write to it.
- The shared `compatdata` bind-mount target is `root:root`, mode `000` when
  nothing is mounted — it cannot be read or written directly.
- The session mount script is owned by root and filters strictly on `gamers`
  group membership; it takes no untrusted input and hardcodes no usernames.
- No network access, no daemons, no setuid binaries are introduced. The only
  privileged component is a root-owned script invoked by PAM at login.

---

## Filesystem support

| Filesystem | Status                                                                                                |
| ---------- | ----------------------------------------------------------------------------------------------------- |
| ZFS        | Fully tested                                                                                          |
| ext4       | Fully tested                                                                                          |
| XFS        | Expected to work (standard POSIX semantics)                                                           |
| btrfs      | Works; copy-on-write can affect setgid inheritance — the migration re-applies ownership to compensate |
| F2FS       | Untested; no known blocker                                                                            |
| bcachefs   | Untested; considered experimental upstream                                                            |

Bind mounts and `nsenter` operate at the kernel VFS layer and are
filesystem-agnostic, so the core mechanism works regardless of the underlying
filesystem.

---

## Uninstalling

```sh
# Remove the PAM hook
sudo sed -i '/steam-session-mount.sh/d' /etc/pam.d/system-login

# Remove the installed scripts
sudo rm -f /usr/local/bin/steam-multiuser.sh \
           /usr/local/bin/steam-session-mount.sh \
           /usr/local/bin/steam-compatdata-mount.sh

# Optional: remove the config and the gamers group
sudo rm -f /etc/steam-multiuser.conf
sudo groupdel gamers
```

Game files in the shared library are left untouched. Each user can move them back
into their home `steamapps` or point Steam at the shared path as a normal
(single-user) library afterward.

---

## Contributing

Issues and pull requests are welcome. The entire tool is a single Bash script
(`steam-multiuser.sh`) plus packaging; it passes `shellcheck` cleanly at warning
severity. Please run `shellcheck steam-multiuser.sh` and `bash -n steam-multiuser.sh`
before submitting, and test changes against `--check` on a real setup where
possible.

---

## License

Released under the **GNU General Public License v2.0 or later**
(`GPL-2.0-or-later`). See [LICENSE](LICENSE).
