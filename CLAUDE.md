## CLAUDE.md

This repo is a single generic bootstrap script for a Dokploy server: a VPS running its
own Dokploy, or (with `DOKPLOY_REMOTE` / `LAN_CIDR`) a remote server managed by a
Dokploy elsewhere, including one on a private network. It holds no facts about any
particular machine — every host-specific value is an input. Keep it that
way: host facts belong in the operator's own notes, or in a site overlay.

## Git commits

Use Conventional Commits: `<type>[optional scope]: <description>` (e.g. `feat(auth): add login`, `fix: handle null input`).

## Terminal commands

When providing shell commands for the user to copy-paste into a terminal, never use heredocs (`<<'EOF'`). Indentation in chat output causes the `EOF` terminator to not be recognised. Use `printf` with `\n` escapes instead to write multi-line file content.
