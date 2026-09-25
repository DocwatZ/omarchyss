import importlib.util
import importlib.machinery
import json
import os
import stat
import tempfile
import unittest
from unittest import mock
import urllib.error


MODULE_PATH = os.path.join(
    os.path.dirname(os.path.dirname(__file__)), "bin", "omarchyss-spotify"
)
LOADER = importlib.machinery.SourceFileLoader("omarchyss_spotify", MODULE_PATH)
SPEC = importlib.util.spec_from_loader("omarchyss_spotify", LOADER)
spotify = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(spotify)


class Response:
    def __init__(self, body):
        self.body = body
        self.headers = {}
        self.status = 200

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def close(self):
        pass

    def read(self, _size=-1):
        return self.body


class SpotifySecurityTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.config_dir = self.temp_dir.name
        self.config_file = os.path.join(self.config_dir, "spotify.json")
        self.constants = mock.patch.multiple(
            spotify,
            CONFIG_DIR=self.config_dir,
            CONFIG_FILE=self.config_file,
        )
        self.constants.start()

    def tearDown(self):
        self.constants.stop()
        self.temp_dir.cleanup()

    def test_save_preserves_preferences_and_writes_atomically(self):
        spotify.save_config({"client_id": "a" * 32, "preferences": {"textMode": "track"}})
        spotify.save_config({"client_id": "b" * 32})

        with open(self.config_file, encoding="utf-8") as config_file:
            config = json.load(config_file)
        self.assertEqual(config["client_id"], "b" * 32)
        self.assertEqual(config["preferences"], {"textMode": "track"})
        self.assertEqual(stat.S_IMODE(os.stat(self.config_file).st_mode), 0o600)

    def test_symlinked_config_is_rejected(self):
        target = os.path.join(self.temp_dir.name, "outside")
        with open(target, "w", encoding="utf-8") as file:
            file.write("{}")
        os.symlink(target, self.config_file)

        with self.assertRaises(OSError):
            spotify.save_config({})

    def test_symlinked_lock_is_rejected(self):
        os.symlink(self.temp_dir.name, f"{self.config_file}.lock")

        with self.assertRaises(OSError):
            spotify.save_config({})

    def test_unsafe_directory_permissions_are_rejected(self):
        os.chmod(self.config_dir, 0o755)

        with self.assertRaises(PermissionError):
            spotify.save_config({})

    def test_oversized_success_response_is_rejected(self):
        response = Response(b"x" * (spotify.MAX_HTTP_RESPONSE_BYTES + 1))
        with mock.patch.object(spotify.urllib.request, "urlopen", return_value=response):
            with self.assertRaises(ValueError):
                spotify.http_json("https://example.test")

    def test_oversized_error_response_is_rejected(self):
        error = urllib.error.HTTPError(
            "https://example.test", 500, "error", {}, Response(b"x" * (spotify.MAX_HTTP_RESPONSE_BYTES + 1))
        )
        with mock.patch.object(spotify.urllib.request, "urlopen", side_effect=error):
            with self.assertRaises(ValueError):
                spotify.http_json("https://example.test")


if __name__ == "__main__":
    unittest.main()
