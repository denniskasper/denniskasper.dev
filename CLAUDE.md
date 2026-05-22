## CLAUDE.md

Open decisions, workstreams, backlog, feature ideas and platform state for the dev server are in docs/ dashboard.html.

## Git commits

Use Conventional Commits: `<type>[optional scope]: <description>` (e.g. `feat(auth): add login`, `fix: handle null input`).

## Terminal commands

When providing shell commands for the user to copy-paste into a terminal, never use heredocs (`<<'EOF'`). Indentation in chat output causes the `EOF` terminator to not be recognised. Use `printf` with `\n` escapes instead to write multi-line file content.
