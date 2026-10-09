# Contributing to AI Mac Cleaner

Thanks for considering a contribution. This is a personal-maintained project, so every PR gets read — but patience is genuinely appreciated.

## What helps most

Roughly in order of usefulness to the maintainer:

1. **Bug reports with real detail.** Which macOS version, which app were you uninstalling, what did you expect, what happened instead. A screenshot of the About page (with the version build) helps.
2. **Missing leftover rules.** The scanner knows about ~15 AI coding tools, ML frameworks, and package managers. If there's one it misses, tell me which tool and where its data lives (`~/Library/Application Support/…`, `~/.config/…`, etc.).
3. **Small fixes** — typos, dead code, comments that no longer match the code.
4. **Translations.** The app ships English and Simplified Chinese.

## Before you open a PR

- **Keep it focused.** One logical change per PR makes review fast and merge painless.
- **Match the existing style.** Swift, 4-space indent, `//` comments in the same language the surrounding file uses. Run `swift build` and make sure it compiles clean.
- **Say what and why in the description.** Especially for cleanup logic — scanners here decide what gets deleted from someone's machine. Explain how you verified it's safe.

## Pull requests

- Branch off `main`.
- `git commit` messages in the imperative mood, matching the existing history style (this repo uses Chinese commit subjects describing the user-visible change, not the internal refactor).
- If a PR touches the removal logic (`Sources/AIMacCleaner/Executor/`, `Scanners/`), say so explicitly. That code runs against real user data and gets reviewed more carefully.

## Reporting security issues

Please don't open a public issue for anything exploitable — file an issue marked as a private security advisory on the repo, or ping the maintainer directly.

## Code of conduct

Be decent. See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

## License

Contributions are accepted under the [MIT License](LICENSE). By submitting a PR you confirm you have the right to license your work under it.
