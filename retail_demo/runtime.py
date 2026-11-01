"""Runtime preflight checks for the Snowflake GPU container.

Account, role and data validation live in SQL procedures. This module only
checks what SQL cannot see: the container platform, mounted credentials,
package version and local scratch space. GPU access is left to Kumo itself.
"""
import importlib.metadata
import platform
import shutil
from pathlib import Path

from retail_demo.adapter import DATABASE

REQUIRED_KUMO_VERSION = "1.0.0"
MIN_SCRATCH_BYTES = 5 * 2**30  # 5 GiB for graph snapshots and checkpoints
SPCS_TOKEN_PATH = Path("/snowflake/session/token")


def check_identity(session, expected_account):
    """Fail unless the session is the approved account and restricted ML role.

    Secondary roles are disabled first so privileges from inherited roles
    (for example the data owner) cannot leak into the run.
    Returns the active warehouse name.
    """
    session.sql("USE SECONDARY ROLES NONE").collect()
    session.sql(
        f"CALL {DATABASE}.RESULTS.V2_ASSERT_IDENTITY(?)", params=[expected_account]
    ).collect()
    return session.sql("SELECT CURRENT_WAREHOUSE()").collect()[0][0]


def runtime_preflight(session, expected_account, scratch_dir):
    """Verify identity and the GPU runtime before any local writes or training.

    Any failed check stops the run. Returns the active warehouse name.
    """
    # The account gate runs before anything touches local disk.
    warehouse = check_identity(session, expected_account)

    if platform.system() != "Linux" or platform.machine() != "x86_64":
        raise RuntimeError("Approved Snowflake Linux x86 GPU runtime required")
    if not SPCS_TOKEN_PATH.is_file():
        raise RuntimeError("Mounted runtime credentials unavailable")
    if importlib.metadata.version("kumo-engine") != REQUIRED_KUMO_VERSION:
        raise RuntimeError(f"Kumo Engine {REQUIRED_KUMO_VERSION} required")

    scratch = Path(scratch_dir)
    scratch.mkdir(parents=True, exist_ok=True)
    if shutil.disk_usage(scratch).free < MIN_SCRATCH_BYTES:
        raise RuntimeError("At least 5 GiB scratch required")
    return warehouse
