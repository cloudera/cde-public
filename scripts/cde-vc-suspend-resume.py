import time
import subprocess
import json
import argparse
import logging

# ------------------------------
# Logging Setup
# ------------------------------

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S"
)

log = logging.getLogger(__name__)

# ------------------------------
# Status Constants
# ------------------------------

STATUS_MAP = {
    "suspend": {
        "cmd": "suspend-vc",
        "success": "suspend completed, please proceed with resume",
        "failed": "AppSuspendFailed",
    },
    "resume": {
        "cmd": "resume-vc",
        "success": "virtual cluster is running",
        "failed": "AppResumeFailed",
    }
}

# ------------------------------
# Friendly Error Parsing
# ------------------------------

def parse_cdp_error(stderr: str) -> str:
    stderr = stderr or ""

    if "AppInstalled" in stderr:
        return "Resume failed: VC is in 'AppInstalled' state (nothing to resume)."

    if "instance is in: AppSuspended" in stderr:
        return "Suspend failed: VC is already in 'AppSuspended' state."

    if "NOT_FOUND" in stderr:
        return "Operation failed: VC not found."

    if "PERMISSION" in stderr.upper():
        return "Operation failed: Permission denied."

    return "Operation failed due to a CDP CLI error."


# ------------------------------
# Utility Functions
# ------------------------------

def run_cdp_command(command):
    try:
        result = subprocess.run(
            command,
            capture_output=True,
            text=True,
            check=False
        )
    except Exception as e:
        clean_msg = f"Unexpected failure executing CDP CLI: {e}"
        return {"_error": clean_msg}

    if result.returncode != 0:
        clean_msg = parse_cdp_error(result.stderr)
        return {"_error": clean_msg}

    try:
        return json.loads(result.stdout or "{}")
    except json.JSONDecodeError:
        return {"_error": "Invalid JSON from CDP"}

# ------------------------------
# Polling Logic
# ------------------------------

def wait_for_cluster(cluster_id, vc_id, success_state, failed_state, profile_name, operation):
    """Polls cluster state until success/failure."""
    while True:
        cmd = [
            "cdp", "de", "get-suspend-resume-status",
            "--cluster-id", cluster_id,
            "--vc-id", vc_id,
            "--profile", profile_name,
        ]

        response = run_cdp_command(cmd)

        if not response or "_error" in response:
            log.error(f"[{cluster_id}] | [{vc_id}] | Unable to fetch cluster status. Retrying in 30 seconds.")
            time.sleep(30)
            continue

        status = response.get("status") or response.get("statusMessage")

        log.info(f"[{cluster_id}] | [{vc_id}] | VC Status: {status}")

        if status == success_state:
            log.info(f"[{cluster_id}] | [{vc_id}] | {operation.upper()} completed successfully.")
            return True

        if status == failed_state:
            log.error(f"[{cluster_id}] | [{vc_id}] | {operation} failed (status = {status}).")
            return False

        log.info(f"[{cluster_id}] | [{vc_id}] | Operation still in progress... checking again in 30 seconds.")
        time.sleep(30)

# ------------------------------
# VC Operation Logic (Single VC)
# ------------------------------

def run_vc_operation(operation, cluster_id, vc_id, profile_name):
    op = STATUS_MAP[operation]
    max_retries = 3
    retry_delay = 20

    for attempt in range(1, max_retries + 1):
        log.info(f"Attempt {attempt}/{max_retries}: Initiated {operation.upper()} for ClusterId: {cluster_id} | VcID: {vc_id} ...")

        command = [
            "cdp", "de", op["cmd"],
            "--cluster-id", cluster_id,
            "--vc-id", vc_id,
            "--profile", profile_name,
        ]

        response = run_cdp_command(command)

        # -------------------------------
        # EARLY EXIT LOGIC
        # -------------------------------
        if response and "_error" in response:
            msg = response["_error"]

            # NON-RETRYABLE ERRORS
            if (
                "AppInstalled" in msg
                or "AppSuspended" in msg
                or "not found" in msg.lower()
                or "permission" in msg.lower()
            ):
                log.error(f"[{cluster_id}] | [{vc_id}] | Fatal error: {msg}")
                return

            # RETRYABLE ERRORS
            if attempt < max_retries:
                log.warning(f"[{cluster_id}] | [{vc_id}] | {operation} failed. Retrying in {retry_delay} seconds...")
                time.sleep(retry_delay)
                continue

            log.error(f"[{cluster_id}] | [{vc_id}] | {operation} failed after {max_retries} attempts.")
            return

        # -------------------------------
        # SUCCESSFUL CLI → POLLING
        # -------------------------------
        success = wait_for_cluster(
            cluster_id, vc_id,
            op["success"], op["failed"],
            profile_name, operation,
        )

        if success:
            return

        # FAIL INSIDE POLLING
        if attempt < max_retries:
            log.warning(f"[{cluster_id}] | [{vc_id}] | VC failure state. Retrying in {retry_delay} seconds...")
            time.sleep(retry_delay)
            continue

        log.error(f"[{cluster_id}] | [{vc_id}] | {operation} failed after {max_retries} attempts.")
        return

    return


# ------------------------------
# Main (Multi-VC Support)
# ------------------------------

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Suspend/Resume VC using CDP CLI")
    parser.add_argument('--cluster-id', required=True)
    parser.add_argument('--vc-ids', required=True, nargs='+', help='One or more Virtual Cluster IDs')
    parser.add_argument('--operation', required=True, choices=["suspend", "resume"])
    parser.add_argument('--profile', required=True)

    args = parser.parse_args()

    for vc_id in args.vc_ids:
        run_vc_operation(args.operation, args.cluster_id, vc_id, args.profile)

