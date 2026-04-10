# Offload Repo Initialization

You are running in the working directory of a git repository. Your task is to "onboard" this repo to the Offload system by reading the codebase and producing a set of long-term context files that future Offload agent runs (including yourself, in later sessions) will use to understand this repo without re-reading everything from scratch.

## What you must do

1. **Read the repo.** Read at minimum:
   - The top-level `README.md` (or equivalent) if it exists
   - The package manifest (`package.json`, `Cargo.toml`, `pyproject.toml`, `go.mod`, `Gemfile`, etc.)
   - The top-level directory structure
   - 3–10 representative source files (entry points, main modules)

2. **Write four context files** under `.offload/context/`. **REPLACE** any existing content in these files.
   - `.offload/context/summary.md`
   - `.offload/context/architecture.md`
   - `.offload/context/conventions.md`
   - `.offload/context/glossary.md`

   Skeleton templates are at `.offload/init/templates/*.template.md`. Use them as a guide; you don't have to follow them rigidly.

3. **Critical requirement for `summary.md`:** the FIRST paragraph (after the heading) MUST be a single self-contained one-paragraph summary, ≤ 300 characters. This first paragraph is what gets shown on the Offload phone client's project cards, so make it punchy and informative. Additional content can go below.

## Constraints

- Be **concrete**. Write what's actually in this repo, not generic advice. Name real modules, real classes, real conventions.
- If the repo is small or unclear, write what you can. **Don't fabricate.** It's fine for `glossary.md` to be empty if there are no domain-specific terms.
- **CRITICAL: Do NOT modify, create, or delete any files outside `.offload/`.** Offload is an observer tool, like git — it never touches source code. This is a hard invariant, not a suggestion. Any source changes you make will be automatically reverted after this run.
- **Do NOT run tests, formatters, linters, or build commands.** Read-only analysis only.
- **Do NOT run git commands** (no commits, no branch switches, no stash).
- Don't ask the user questions — produce the files in one shot from what you can read.

## Output format

Each file should be markdown. Headings start at `#`. Keep total length reasonable (a few hundred to a few thousand words across all four files combined).

When you're done, all four files at `.offload/context/*.md` should exist with real content. That's the success criterion.
