# Ubuntu 24.04 IBus/LibPinyin Migration

[中文](README.zh-CN.md) | English

A cautious, reversible migration tool for moving a GNOME IBus/LibPinyin setup
between Ubuntu 24.04 machines.

It migrates:

- GNOME input sources and input-source keyboard shortcuts
- IBus and LibPinyin dconf settings
- LibPinyin learned phrases, frequencies, and user dictionaries
- The user-level input method selector
- A package manifest used to install only missing dependencies

It also handles a common failure mode that we encountered in real use:
Fcitx5 may keep auto-starting and claim the IBus D-Bus name even after
`im-config` selects IBus. Import backs up and removes the per-user Fcitx5
autostart entry and Fcitx overrides in `~/.pam_environment`.

## Requirements

- Ubuntu 24.04 with GNOME
- Run as the logged-in desktop user, **not** with `sudo`
- `ibus-libpinyin` on the source machine

The importer invokes `sudo` only if required packages are missing.

## Quick start

On the source machine:

```bash
chmod +x input-method-migrate.sh
./input-method-migrate.sh export
```

Copy the script and generated `.tar.gz` bundle to the destination. Inspect
before importing:

```bash
./input-method-migrate.sh inspect ./ubuntu24-input-method-*.tar.gz
./input-method-migrate.sh import ./ubuntu24-input-method-*.tar.gz
```

Log out and back in once, then verify:

```bash
./input-method-migrate.sh check
```

Use **Super+Space** to switch input sources.

## Backups and rollback

Every import creates a snapshot under:

```text
~/.local/state/input-method-migrate/backups/
```

List and restore snapshots:

```bash
./input-method-migrate.sh list-backups
./input-method-migrate.sh rollback /absolute/path/to/before-import
```

Rollback itself creates another safety snapshot.

## Security notes

- Import only bundles you created or trust.
- Bundles are SHA-256 verified before use.
- Archive paths are checked before extraction.
- Existing destination data is backed up before replacement.
- Package names are validated and only missing packages are installed.

## What is intentionally not migrated

- IBus runtime sockets
- Regenerable registry caches
- System-wide configuration
- Passwords, secrets, or unrelated desktop settings

## Troubleshooting

If `check` reports that Fcitx5 owns IBus, inspect:

```bash
~/.config/autostart/fcitx5.desktop
~/.pam_environment
```

The importer normally backs up and resolves both. A logout/login is required
because GUI applications inherit input-method environment variables at login.

## License

MIT
