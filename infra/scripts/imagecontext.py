#!/usr/bin/env python3

import hashlib
from pathlib import Path
import shutil
import stat
import sys


STATIC_IMAGE_INPUTS = (
    ".dockerignore",
    "Dockerfile",
    "go.mod",
    "go.sum",
    "host.json",
)


def _copy_entry(source: Path, destination: Path) -> None:
    if source.is_symlink():
        raise ValueError(f"Symbolic links are not allowed: {source}")
    if source.is_dir():
        destination.mkdir(mode=0o755)
        for child in sorted(source.iterdir(), key=lambda path: path.name):
            _copy_entry(child, destination / child.name)
        return
    if not source.is_file():
        raise ValueError(f"Unsupported image-context entry: {source}")

    shutil.copyfile(source, destination)
    destination.chmod(
        stat.S_IRUSR | stat.S_IWUSR | stat.S_IRGRP | stat.S_IROTH
    )


def hash_image_context(context_root: Path) -> str:
    root = context_root.resolve()
    digest = hashlib.sha256()
    digest.update(b"flex-container-go-image-context-v1\0")

    def visit(path: Path) -> None:
        relative = path.relative_to(root).as_posix()
        if path.is_symlink():
            raise ValueError(f"Symbolic links are not allowed: {path}")
        if path.is_dir():
            digest.update(f"directory\0{relative}\0".encode())
            for child in sorted(path.iterdir(), key=lambda item: item.name):
                visit(child)
            return
        if not path.is_file():
            raise ValueError(f"Unsupported image-context entry: {path}")

        content = path.read_bytes()
        digest.update(f"file\0{relative}\0{len(content)}\0".encode())
        digest.update(content)
        digest.update(b"\0")

    for entry in sorted(root.iterdir(), key=lambda path: path.name):
        visit(entry)
    return digest.hexdigest()


def image_inputs(repository_root: Path) -> tuple[Path, ...]:
    repository = repository_root.resolve()
    inputs = [repository / name for name in STATIC_IMAGE_INPUTS]
    go_files = sorted(repository.glob("*.go"), key=lambda path: path.name)
    if not go_files:
        raise FileNotFoundError(
            f"No root-level Go source files were found in {repository}"
        )
    inputs.extend(go_files)
    return tuple(inputs)


def prepare_image_context(
    repository_root: Path,
    destination_root: Path,
) -> str:
    repository = repository_root.resolve()
    destination = destination_root.resolve()
    destination.mkdir(parents=True, mode=0o755, exist_ok=True)
    if any(destination.iterdir()):
        raise ValueError(
            f"Image-context destination must be empty: {destination}"
        )

    for source in image_inputs(repository):
        if not source.exists():
            raise FileNotFoundError(f"Required image input is missing: {source}")
        _copy_entry(source, destination / source.name)

    return hash_image_context(destination)


def main() -> int:
    if len(sys.argv) != 2:
        print(
            "Usage: python infra/scripts/imagecontext.py "
            "<empty-destination-directory>",
            file=sys.stderr,
        )
        return 2

    repository_root = Path(__file__).resolve().parents[2]
    try:
        context_hash = prepare_image_context(
            repository_root,
            Path(sys.argv[1]),
        )
    except (OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        return 1

    print(context_hash)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
