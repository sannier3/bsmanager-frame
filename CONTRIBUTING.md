# Contributing

Thanks for helping improve BSManager Frame.

## Scope

This project targets **Valve Steam Frame ARM64 / SteamOS**. Keep changes focused
on that platform unless a change is clearly shared infrastructure.

## Single runtime source

All runtime logic must live in **`bsmanager-frame.sh`**.

- Do not split helpers into additional shell or Python source files.
- Embedded Python is allowed only via heredocs inside `bsmanager-frame.sh`.
- Documentation, CI, and metadata may live outside the script.

## Local checks

Before opening a pull request, run:

```bash
bash -n bsmanager-frame.sh
shellcheck bsmanager-frame.sh
```

Also smoke-test:

```bash
bash bsmanager-frame.sh --help
bash bsmanager-frame.sh --version
bash bsmanager-frame.sh --dry-run diagnose
```

## Safety rules

- No `sudo` in runtime code.
- Quote shell variables.
- Avoid destructive commands; validate paths before removal.
- Never edit Steam VDF files while Steam is running.
- Prefer feature detection over undocumented Steam APIs.
- Do not invent BSManager config formats or Steam API signatures.
- Prefer official GitHub/Steam sources.
- Do not redistribute Beat Saber, mods, or proprietary binaries.

## Licensing

By contributing, you agree that your contributions are licensed under the
GNU General Public License v3.0 (see `LICENSE`).
