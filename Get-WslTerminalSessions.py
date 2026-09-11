#!/usr/bin/env python3

import os
import re
import sqlite3
import subprocess


def read_environment(path):
    entries = open(path, "rb").read().split(b"\0")
    return {
        key.decode(errors="replace"): value.decode(errors="replace")
        for entry in entries
        if b"=" in entry
        for key, value in (entry.split(b"=", 1),)
    }


def clean(value):
    return value.replace("\t", " ").replace("\r", " ").replace("\n", " ")


def resolve_codex_session(process_path, environment):
    session_id = environment.get("TERMINAL_CODEX_SESSION_ID", "")
    session_name = environment.get("TERMINAL_CODEX_SESSION_NAME", "")
    lock_ids = []
    state_database = None
    state_directory = None

    for descriptor in os.scandir(os.path.join(process_path, "fd")):
        try:
            target = os.readlink(descriptor.path)
        except FileNotFoundError:
            continue

        lock_match = re.search(r"/thread-writer-locks/([^/]+)\.lock$", target)
        if lock_match:
            lock_ids.append(lock_match.group(1))
            state_directory = os.path.dirname(os.path.dirname(target))
        elif re.search(r"/state_[0-9]+\.sqlite$", target):
            state_database = target

    lookup_ids = lock_ids
    if not lookup_ids and session_id:
        lookup_ids = [session_id]
        state_directory = (
            environment["CODEX_HOME"]
            if "CODEX_HOME" in environment
            else os.path.join(environment["HOME"], ".codex")
        )

    if lookup_ids and not state_database:
        databases = [
            (int(match.group(1)), entry.path)
            for entry in os.scandir(state_directory)
            if (match := re.fullmatch(r"state_([0-9]+)\.sqlite", entry.name))
        ]
        if databases:
            state_database = max(databases)[1]

    if not lookup_ids or not state_database:
        return session_id, session_name

    placeholders = ",".join("?" for _ in lookup_ids)
    connection = sqlite3.connect(f"file:{state_database}?mode=ro", uri=True)
    row = connection.execute(
        f"""
        select id, coalesce(nullif(name, ''), nullif(title, ''), id)
        from threads
        where id in ({placeholders}) and source = 'cli'
        order by recency_at_ms desc, updated_at_ms desc
        limit 1
        """,
        lookup_ids,
    ).fetchone()
    connection.close()

    return row if row else (session_id, session_name)


def tmux_socket(environment):
    tmux = environment.get("TMUX", "")
    return tmux.rsplit(",", 2)[0] if tmux else ""


def tmux_output(socket_path, *arguments):
    return subprocess.run(
        ("tmux", "-S", socket_path, *arguments),
        check=True,
        capture_output=True,
        text=True,
    ).stdout.splitlines()


def is_codex_process(arguments):
    return any(os.path.basename(argument) == "codex" for argument in arguments) and "app-server" not in arguments


def print_row(process, terminal_session, workspace, tmux_fields=("", "", "", "", "", "", "", "")):
    fields = (
        terminal_session,
        process["directory"],
        "1" if process["is_codex"] else "0",
        workspace,
        process.get("tab_id", ""),
        process.get("pane_index", ""),
        process["session_id"],
        process["session_name"],
        *tmux_fields,
    )
    print("\t".join(clean(field) for field in fields))


processes = []
for process in os.scandir("/proc"):
    if not process.name.isdigit():
        continue

    try:
        environment = read_environment(os.path.join(process.path, "environ"))
        terminal_session = environment.get("WT_SESSION", "")
        pane_id = environment.get("TMUX_PANE", "")
        if not terminal_session and not pane_id:
            continue

        working_directory = os.readlink(os.path.join(process.path, "cwd"))
        arguments = [
            argument.decode(errors="replace")
            for argument in open(os.path.join(process.path, "cmdline"), "rb").read().split(b"\0")
            if argument
        ]
        is_codex = is_codex_process(arguments)
        session_id, session_name = ("", "")
        if is_codex:
            session_id, session_name = resolve_codex_session(process.path, environment)

        processes.append(
            {
                "pid": int(process.name),
                "directory": working_directory,
                "arguments": arguments,
                "environment": environment,
                "terminal_session": terminal_session,
                "workspace": environment.get("TERMINAL_WORKSPACE_NAME", ""),
                "tab_id": environment.get("TERMINAL_WORKSPACE_TAB_ID", ""),
                "pane_index": environment.get("TERMINAL_WORKSPACE_PANE_INDEX", ""),
                "is_codex": is_codex,
                "session_id": session_id,
                "session_name": session_name,
                "tmux_socket": tmux_socket(environment),
                "tmux_pane": pane_id,
            }
        )
    except (FileNotFoundError, PermissionError, ProcessLookupError):
        continue

processes_by_pid = {process["pid"]: process for process in processes}
tmux_processes = [process for process in processes if process["tmux_pane"]]
client_pids = set()
separator = "\x1f"
seen_tmux_sessions = set()

for socket_path in dict.fromkeys(process["tmux_socket"] for process in tmux_processes):
    try:
        clients = tmux_output(
            socket_path,
            "list-clients",
            "-F",
            separator.join(
                (
                    "#{client_pid}",
                    "#{session_name}",
                )
            ),
        )
        clients_by_session = {}
        for client_line in clients:
            client_pid_text, session_name = client_line.split(separator, 1)
            client_pid = int(client_pid_text)
            client_pids.add(client_pid)
            client = processes_by_pid.get(client_pid)
            if client and client["terminal_session"] and session_name not in clients_by_session:
                clients_by_session[session_name] = client

        session_names = tmux_output(socket_path, "list-sessions", "-F", "#{session_name}")
        for session_name in session_names:
            session_key = (socket_path, session_name)
            if session_key in seen_tmux_sessions:
                continue
            seen_tmux_sessions.add(session_key)
            client = clients_by_session.get(session_name)
            session_processes = [
                process for process in tmux_processes if process["tmux_socket"] == socket_path
            ]
            terminal_session = client["terminal_session"] if client else ""
            workspace = client["workspace"] if client else next(
                (process["workspace"] for process in session_processes if process["workspace"] == session_name),
                next((process["workspace"] for process in session_processes if process["workspace"]), ""),
            )

            window_lines = tmux_output(
                socket_path,
                "list-windows",
                "-t",
                session_name,
                "-F",
                separator.join(
                    (
                        "#{window_id}",
                        "#{window_index}",
                        "#{window_name}",
                        "#{window_layout}",
                    )
                ),
            )
            for window_line in window_lines:
                window_id, window_index, window_name, layout = window_line.split(separator, 3)
                pane_lines = tmux_output(
                    socket_path,
                    "list-panes",
                    "-t",
                    window_id,
                    "-F",
                    separator.join(
                        (
                            "#{pane_id}",
                            "#{pane_index}",
                            "#{pane_active}",
                            "#{pane_current_path}",
                        )
                    ),
                )
                for pane_line in pane_lines:
                    pane_id, pane_index, pane_active, pane_directory = pane_line.split(separator, 3)
                    pane_processes = [
                        process
                        for process in tmux_processes
                        if process["tmux_socket"] == socket_path and process["tmux_pane"] == pane_id
                    ]
                    if not pane_processes:
                        pane_processes = [
                            {
                                "directory": pane_directory,
                                "is_codex": False,
                                "session_id": "",
                                "session_name": "",
                                "tab_id": "",
                                "pane_index": pane_index,
                            }
                        ]
                    tmux_fields = (
                        session_name,
                        window_id,
                        window_index,
                        window_name,
                        layout,
                        pane_id,
                        pane_index,
                        pane_active,
                    )
                    for pane_process in pane_processes:
                        print_row(
                            pane_process,
                            terminal_session,
                            pane_process.get("workspace", "") or workspace,
                            tmux_fields,
                        )
    except (subprocess.CalledProcessError, ValueError) as error:
        raise RuntimeError(f"Could not inspect tmux socket: {socket_path}") from error

for process in processes:
    if not process["terminal_session"] or process["tmux_pane"] or process["pid"] in client_pids:
        continue
    print_row(process, process["terminal_session"], process["workspace"])
