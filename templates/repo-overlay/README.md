# Repo overlay

Everything a product repo keeps: a version pin plus pointers. Copy both files, set the pin, run the installer.

## `.agent-kit-version`

One line: the kit tag this repo installs (for example `v0.1.0`).

## `AGENTS.md` (overlay)

Keep it to pointers: who owns this repo, where its services start and stop, and the two or three docs that define its contracts. Everything shared stays in the kit. See `AGENTS.md.overlay.example` in this folder.
