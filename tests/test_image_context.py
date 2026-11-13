import importlib.util
from pathlib import Path
import tempfile
import unittest


SCRIPT_PATH = (
    Path(__file__).resolve().parents[1]
    / "infra"
    / "scripts"
    / "imagecontext.py"
)
SPEC = importlib.util.spec_from_file_location("imagecontext", SCRIPT_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"Unable to load {SCRIPT_PATH}")
IMAGECONTEXT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(IMAGECONTEXT)


class ImageContextTests(unittest.TestCase):
    def make_repository(self, root: Path) -> None:
        files = {
            ".dockerignore": "*\n!*.go\n",
            "Dockerfile": "FROM scratch\n",
            "go.mod": "module example.test/sample\n\ngo 1.27.0\n",
            "go.sum": "",
            "host.json": '{"version":"2.0"}\n',
            "main.go": "package main\nfunc main() {}\n",
            "handler.go": "package main\n",
            "README.md": "not part of the image\n",
        }
        for name, content in files.items():
            (root / name).write_text(content, encoding="utf-8")

    def prepare(self, repository: Path) -> tuple[str, set[str]]:
        destination = repository.parent / f"{repository.name}-context"
        context_hash = IMAGECONTEXT.prepare_image_context(
            repository,
            destination,
        )
        names = {path.name for path in destination.iterdir()}
        return context_hash, names

    def test_context_contains_static_and_all_go_inputs(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repository = Path(temporary) / "repository"
            repository.mkdir()
            self.make_repository(repository)

            _, names = self.prepare(repository)

            self.assertEqual(
                names,
                {
                    ".dockerignore",
                    "Dockerfile",
                    "go.mod",
                    "go.sum",
                    "handler.go",
                    "host.json",
                    "main.go",
                },
            )

    def test_unrelated_file_does_not_change_hash(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            first = root / "first"
            second = root / "second"
            first.mkdir()
            second.mkdir()
            self.make_repository(first)
            self.make_repository(second)
            (second / "README.md").write_text("changed\n", encoding="utf-8")

            first_hash, _ = self.prepare(first)
            second_hash, _ = self.prepare(second)

            self.assertEqual(first_hash, second_hash)

    def test_go_source_change_changes_hash(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            first = root / "first"
            second = root / "second"
            first.mkdir()
            second.mkdir()
            self.make_repository(first)
            self.make_repository(second)
            (second / "handler.go").write_text(
                "package main\nvar changed = true\n",
                encoding="utf-8",
            )

            first_hash, _ = self.prepare(first)
            second_hash, _ = self.prepare(second)

            self.assertNotEqual(first_hash, second_hash)

    def test_missing_required_input_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repository = Path(temporary) / "repository"
            repository.mkdir()
            self.make_repository(repository)
            (repository / "go.sum").unlink()

            with self.assertRaises(FileNotFoundError):
                self.prepare(repository)


if __name__ == "__main__":
    unittest.main()
