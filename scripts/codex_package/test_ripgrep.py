import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from codex_package import ripgrep
from codex_package.targets import TARGET_SPECS


class FetchRipgrepTest(unittest.TestCase):
    def test_unlisted_target_uses_rg_from_path(self) -> None:
        spec = TARGET_SPECS["loongarch64-unknown-linux-gnu"]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = root / "rg.json"
            manifest.write_text(json.dumps({"platforms": {}}), encoding="utf-8")
            system_rg = root / "rg"
            system_rg.write_bytes(b"ripgrep")

            with patch.object(
                ripgrep.shutil, "which", return_value=str(system_rg)
            ) as which:
                result = ripgrep.fetch_rg(spec, manifest_path=manifest)

            self.assertEqual(result, system_rg.resolve())
            which.assert_called_once_with("rg")

    def test_unlisted_target_without_rg_from_path_fails_with_hint(self) -> None:
        spec = TARGET_SPECS["loongarch64-unknown-linux-gnu"]
        with tempfile.TemporaryDirectory() as temporary:
            manifest = Path(temporary) / "rg.json"
            manifest.write_text(json.dumps({"platforms": {}}), encoding="utf-8")

            with (
                patch.object(ripgrep.shutil, "which", return_value=None),
                self.assertRaisesRegex(RuntimeError, "pass --rg-bin"),
            ):
                ripgrep.fetch_rg(spec, manifest_path=manifest)


if __name__ == "__main__":
    unittest.main()
