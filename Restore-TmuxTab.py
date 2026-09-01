#!/usr/bin/env python3

import base64
import json
import os
import re
import shlex
import subprocess
import sys


payload = json.loads(base64.b64decode(sys.argv[1]).decode("utf-8"))
workspace_name = payload["workspaceName"]
tabs = payload["tabs"]
if not tabs:
    raise ValueError("A tmux workspace must contain at least one window.")
if ":" in workspace_name or "." in workspace_name:
    raise ValueError("tmux session names cannot contain ':' or '.'.")


def pane_command(tab_index, pane):
    command = [
        "env",
        f"TERMINAL_WORKSPACE_NAME={workspace_name}",
        f"TERMINAL_WORKSPACE_TAB_ID={tab_index}",
        f"TERMINAL_WORKSPACE_PANE_INDEX={pane['index']}",
    ]
    if pane["mode"] == "codex":
        session_id = pane["sessionId"]
        if session_id != "last" and not re.fullmatch(r"[A-Za-z0-9._-]+", session_id):
            raise ValueError("Codex panes require a valid exact session ID.")
        command.append(f"TERMINAL_CODEX_SESSION_ID={session_id}")
        resume_command = "codex resume --last" if session_id == "last" else f"codex resume {session_id}"
        resume = f"{resume_command}; exec zsh -l"
        command.extend(("zsh", "-lic", resume))
    elif pane["mode"] == "shell":
        command.extend(("zsh", "-l"))
    else:
        raise ValueError("tmux pane mode must be 'codex' or 'shell'.")
    return shlex.join(command)


def validate_tab(tab):
    panes = tab["panes"]
    splits = tab["layout"]["splits"]
    if not panes:
        raise ValueError("Every tmux window must contain at least one pane.")
    if len(splits) != len(panes) - 1:
        raise ValueError("Every pane after pane 0 requires one split.")
    for position, pane in enumerate(panes):
        if pane["index"] != position:
            raise ValueError("tmux pane indexes must be sequential and start at zero.")
        if not pane["directory"].startswith("/"):
            raise ValueError("tmux pane directories must be absolute WSL paths.")
    for split in splits:
        if split["direction"] not in ("right", "down"):
            raise ValueError("Split direction must be 'right' or 'down'.")
        if not 0 < split["size"] < 1:
            raise ValueError("Split size must be between 0 and 1.")
    active_pane = tab["layout"]["activePane"]
    if active_pane < 0 or active_pane >= len(panes):
        raise ValueError("activePane must identify one of the saved panes.")


for tab in tabs:
    validate_tab(tab)

has_session = subprocess.run(
    ("tmux", "has-session", "-t", workspace_name),
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
)
if has_session.returncode not in (0, 1):
    raise subprocess.CalledProcessError(has_session.returncode, has_session.args)

if has_session.returncode == 0:
    os.execvp("tmux", ("tmux", "attach-session", "-t", workspace_name))

created = False
try:
    terminal_size = os.get_terminal_size()
    for tab_index, tab in enumerate(tabs):
        first_pane = tab["panes"][0]
        if tab_index == 0:
            subprocess.run(
                (
                    "tmux",
                    "new-session",
                    "-d",
                    "-s",
                    workspace_name,
                    "-x",
                    str(terminal_size.columns),
                    "-y",
                    str(terminal_size.lines),
                    "-n",
                    tab["name"],
                    "-c",
                    first_pane["directory"],
                    pane_command(tab_index, first_pane),
                ),
                check=True,
            )
            created = True
            window_id = subprocess.run(
                ("tmux", "display-message", "-p", "-t", f"{workspace_name}:0", "#{window_id}"),
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()
        else:
            window_id = subprocess.run(
                (
                    "tmux",
                    "new-window",
                    "-d",
                    "-P",
                    "-F",
                    "#{window_id}",
                    "-t",
                    workspace_name,
                    "-n",
                    tab["name"],
                    "-c",
                    first_pane["directory"],
                    pane_command(tab_index, first_pane),
                ),
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()

        pane_targets = subprocess.run(
            ("tmux", "list-panes", "-t", window_id, "-F", "#{pane_id}"),
            check=True,
            capture_output=True,
            text=True,
        ).stdout.splitlines()
        for pane, split in zip(tab["panes"][1:], tab["layout"]["splits"]):
            orientation = "-h" if split["direction"] == "right" else "-v"
            percentage = str(round(split["size"] * 100))
            pane_id = subprocess.run(
                (
                    "tmux",
                    "split-window",
                    "-d",
                    orientation,
                    "-p",
                    percentage,
                    "-t",
                    pane_targets[-1],
                    "-P",
                    "-F",
                    "#{pane_id}",
                    "-c",
                    pane["directory"],
                    pane_command(tab_index, pane),
                ),
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()
            pane_targets.append(pane_id)

        exact_tmux_layout = tab["layout"].get("tmux")
        if exact_tmux_layout:
            subprocess.run(
                ("tmux", "select-layout", "-t", window_id, exact_tmux_layout),
                check=True,
                stdout=subprocess.DEVNULL,
            )
        subprocess.run(
            ("tmux", "select-pane", "-t", pane_targets[tab["layout"]["activePane"]]),
            check=True,
        )
except subprocess.CalledProcessError:
    if created:
        subprocess.run(("tmux", "kill-session", "-t", workspace_name), check=False)
    raise

os.execvp("tmux", ("tmux", "attach-session", "-t", workspace_name))
