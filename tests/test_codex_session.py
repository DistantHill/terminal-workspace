import importlib.util
import json
import pathlib
import sqlite3
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

scanner_path = pathlib.Path(__file__).resolve().parents[1] / 'Get-WslTerminalSessions.py'
spec = importlib.util.spec_from_file_location('scanner', scanner_path)
scanner = importlib.util.module_from_spec(spec)
with patch('os.scandir', return_value=[]):
    spec.loader.exec_module(scanner)


class CodexSessionTests(unittest.TestCase):
    def test_vscode_codex_app_server_is_not_interactive_codex(self):
        self.assertFalse(
            scanner.is_codex_process(
                [
                    '/home/reed/.vscode-server/extensions/openai.chatgpt/bin/codex',
                    '-c',
                    'features.code_mode_host=true',
                    'app-server',
                ]
            )
        )
        self.assertTrue(scanner.is_codex_process(['/usr/local/bin/codex', 'resume', 'thread-a']))

    def test_legacy_session_uses_latest_indexed_thread_name(self):
        with tempfile.TemporaryDirectory() as directory:
            database = pathlib.Path(directory) / 'state_5.sqlite'
            connection = sqlite3.connect(database)
            connection.execute('create table threads (id, name, title, preview, source, recency_at_ms, updated_at_ms)')
            connection.execute("insert into threads values ('thread-a', '', 'Conversation A', 'Preview A', 'cli', 1, 1)")
            connection.commit()
            connection.close()
            (pathlib.Path(directory) / 'session_index.jsonl').write_text(
                '\n'.join(
                    (
                        json.dumps({'id': 'thread-a', 'thread_name': 'Old Name'}),
                        json.dumps({'id': 'thread-a', 'thread_name': 'Latest Name'}),
                    )
                ),
                encoding='utf-8',
            )
            real_scandir = scanner.os.scandir

            def scandir(path):
                if path == '/process/fd':
                    return []
                return real_scandir(path)

            environment = {
                'CODEX_HOME': directory,
                'TERMINAL_CODEX_SESSION_ID': 'thread-a',
            }
            with patch('os.scandir', side_effect=scandir):
                self.assertEqual(
                    scanner.resolve_codex_session('/process', environment),
                    ('thread-a', 'Latest Name'),
                )

    def test_unnamed_session_falls_back_to_title(self):
        with tempfile.TemporaryDirectory() as directory:
            database = pathlib.Path(directory) / 'state_5.sqlite'
            connection = sqlite3.connect(database)
            connection.execute('create table threads (id, name, title, preview, source, recency_at_ms, updated_at_ms)')
            connection.execute("insert into threads values ('thread-a', '', 'Conversation A', 'Preview A', 'cli', 1, 1)")
            connection.commit()
            connection.close()
            environment = {'CODEX_HOME': directory, 'TERMINAL_CODEX_SESSION_ID': 'thread-a'}
            real_scandir = scanner.os.scandir
            with patch('os.scandir', side_effect=lambda path: [] if path == '/process/fd' else real_scandir(path)):
                self.assertEqual(scanner.resolve_codex_session('/process', environment), ('thread-a', 'Conversation A'))

    def test_session_survives_closed_database_descriptor(self):
        with tempfile.TemporaryDirectory() as directory:
            database = pathlib.Path(directory) / 'state_5.sqlite'
            connection = sqlite3.connect(database)
            connection.execute('create table threads (id, name, title, preview, source, recency_at_ms, updated_at_ms)')
            connection.execute("insert into threads values ('thread-a', 'Conversation A', '', '', 'cli', 1, 1)")
            connection.commit()
            connection.close()
            real_scandir = scanner.os.scandir
            lock = str(pathlib.Path(directory) / 'thread-writer-locks' / 'thread-a.lock')
            for database_open in (True, False):
                with self.subTest(database_open=database_open):
                    targets = {'/process/fd/1': lock}
                    if database_open:
                        targets['/process/fd/2'] = str(database)
                    def scandir(path):
                        if path == '/process/fd':
                            return [SimpleNamespace(path=p) for p in targets]
                        return real_scandir(path)
                    with patch('os.scandir', side_effect=scandir), patch('os.readlink', side_effect=targets.__getitem__):
                        self.assertEqual(scanner.resolve_codex_session('/process', {}), ('thread-a', 'Conversation A'))


if __name__ == '__main__':
    unittest.main()
