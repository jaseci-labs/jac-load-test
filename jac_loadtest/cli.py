# JacMetaImporter must be registered before any jac_scale import.
# jac-scale's microservice modules are compiled Jac; without this the import fails.
from jaclang.meta_importer import JacMetaImporter
import sys

if not any(isinstance(f, JacMetaImporter) for f in sys.meta_path):
    sys.meta_path.insert(0, JacMetaImporter())


def run(args: object) -> None:
    raise NotImplementedError(
        "jac loadtest: Phase 1 (HAR replay) not yet implemented. "
        "Run 'jac loadtest --help' to see available flags."
    )
