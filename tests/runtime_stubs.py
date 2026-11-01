"""Placeholder SDK modules so runtime code can be imported in local tests.

The Kumo SDK and kumoapi exist only inside the Snowflake GPU runtime.
Importing this module registers empty stand-ins for any that are missing;
tests then patch the specific attributes they exercise. Real installed
packages are never replaced.
"""
import importlib.util
import sys
from types import ModuleType

_PLACEHOLDERS = {
    "kumo": [],
    "kumo.engine": [],
    "kumoapi": [],
    "kumoapi.graph": ["Edge"],
    "kumoapi.typing": ["Stype"],
    "kumoapi.jobs": ["PredictionArtifactType", "WriteMode"],
    "kumoapi.model_plan": ["RunMode"],
    "kumoapi.train": ["TrainingTableSpec"],
    "snowflake": [],
    "snowflake.ml": [],
    "snowflake.ml.experiment": ["ExperimentTracking"],
}


def _installed(name):
    try:
        return importlib.util.find_spec(name) is not None
    except (ImportError, ValueError):
        return False


for _name, _attributes in _PLACEHOLDERS.items():
    if _name in sys.modules or _installed(_name):
        continue
    _module = ModuleType(_name)
    for _attribute in _attributes:
        setattr(_module, _attribute, None)
    sys.modules[_name] = _module
    _parent, _, _child = _name.rpartition(".")
    if _parent in sys.modules:
        setattr(sys.modules[_parent], _child, _module)
