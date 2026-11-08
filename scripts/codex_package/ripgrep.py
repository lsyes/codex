"""Fetch ripgrep from the DotSlash manifest used by the package builder."""

import shutil
from pathlib import Path

from .dotslash import fetch_dotslash_executable, load_manifest
from .targets import TargetSpec, resolve_input_path

RG_MANIFEST = Path(__file__).with_name("rg")


def resolve_rg_bin(spec: TargetSpec, rg_bin: Path | None) -> Path:
    if rg_bin is not None:
        return resolve_input_path(rg_bin, "ripgrep executable", "--rg-bin")

    return fetch_rg(spec)


def fetch_rg(
    spec: TargetSpec,
    *,
    manifest_path: Path = RG_MANIFEST,
) -> Path:
    manifest = load_manifest(manifest_path)
    if spec.dotslash_platform not in manifest.get("platforms", {}):
        system_rg = shutil.which(spec.rg_name)
        if system_rg is not None:
            rg_bin = Path(system_rg).resolve()
            print(
                f"ripgrep manifest {manifest_path} has no "
                f"{spec.dotslash_platform!r} artifact; using {rg_bin} from PATH."
            )
            return rg_bin
        raise RuntimeError(
            f"ripgrep manifest {manifest_path} has no "
            f"{spec.dotslash_platform!r} artifact and {spec.rg_name!r} "
            "is not on PATH; pass --rg-bin with a compatible executable."
        )

    rg_bin = fetch_dotslash_executable(
        spec,
        manifest_path=manifest_path,
        artifact_label="ripgrep",
        cache_key=f"{spec.target}-rg",
        dest_name=spec.rg_name,
    )
    if rg_bin is None:
        raise AssertionError("ripgrep is required for all package targets")
    return rg_bin
