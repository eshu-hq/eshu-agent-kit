# Pin a product repo

A product repo stays thin: a version pin plus a small overlay. Never
copy kit files into it.

## Steps

1. **Copy the overlay.** Everything local lives in
   [templates/repo-overlay/](../../templates/repo-overlay/): the version
   pin and a pointer-style `AGENTS.md`. Copy both into the repo.
2. **Set the pin.** `.agent-kit-version` is one line — the kit tag the
   repo installs (releases are SemVer git tags; see [VERSION](../../VERSION)).
3. **Run the installer.**

   ```sh
   ./install.sh --repo /path/to/repo
   ```

   This symlinks the skills in and writes the pin. Add `--hooks` or
   `--rules` runs if the repo wants those too (see
   [Install and configure](install-and-configure.md)).
4. **Upgrade later the same way.** Move the pin, re-run the installer.
   Fixes land once in this repo; repos pick them up by re-running.

The overlay's own
[README](../../templates/repo-overlay/README.md) walks through the details.

## Before / after

|  | Before | After |
| --- | --- | --- |
| Skills | Copied per repo, drifted | `install.sh --repo` symlinks them from the kit |
| Hooks | Wired by hand, half missing | The Claude Code plugin registers them, or one installer command links the scripts |
| Fixes | Patched once per repo | Patched once here; repos re-run the installer |
| Versions | "Which copy?" | `.agent-kit-version` in the repo says exactly |
