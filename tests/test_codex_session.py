import importlib.util
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
    def test_session_survives_closed_database_descriptor(self):
        with tempfile.TemporaryDirectory() as directory:
            database = pathlib.Path(directory) / 'state_5.sqlite'
            connection = sqlite3.connect(database)
            connection.execute('create table threads (id, name, title, source, recency_at_ms, updated_at_ms)')
            connection.execute("insert into threads values ('thread-a', 'Conversation A', '', 'cli', 1, 1)")
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
