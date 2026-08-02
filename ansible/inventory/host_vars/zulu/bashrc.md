# zulu — .bashrc not sourced on login (color prompt disappears)

## Symptom

Copied `/etc/skel/.bashrc` to `~/.bashrc` to get the color prompt back. Works when run
manually with `source ~/.bashrc`, but disappears again after logout/login — have to
`source` it every time.

## Cause

`~/.bashrc` is only auto-sourced by **non-login interactive shells**. Logging in
(SSH session, console login) starts bash as a **login shell**, which reads
`~/.profile` (or `~/.bash_profile` / `~/.bash_login` if present) instead, and only
sources `~/.bashrc` if that profile file explicitly does so.

Copying `.bashrc` alone from `/etc/skel/` without the matching `.profile` drops the
snippet that wires the two together.

## Check

```bash
cat ~/.profile 2>/dev/null
```

Debian/Ubuntu's `/etc/skel/.profile` normally ends with:

```bash
if [ -n "$BASH_VERSION" ]; then
    if [ -f "$HOME/.bashrc" ]; then
        . "$HOME/.bashrc"
    fi
fi
```

If `~/.profile` is missing this block (or missing entirely), that's the bug.

## Fix

Copy both skel files together so `.bashrc` and `.profile` stay in sync:

```bash
cp /etc/skel/.bashrc ~/.bashrc
cp /etc/skel/.profile ~/.profile
```

Or, to keep an existing `~/.profile` (just add the missing sourcing snippet instead of
overwriting it):

```bash
cat >> ~/.profile << 'EOF'

if [ -n "$BASH_VERSION" ]; then
    if [ -f "$HOME/.bashrc" ]; then
        . "$HOME/.bashrc"
    fi
fi
EOF
```

Log out and back in — no more manual `source` needed.
