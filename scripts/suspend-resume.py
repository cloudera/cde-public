import time
import subprocess
import json
import argparse
import sys

DE_CLUSTER_MAINTENANCE_COMPLETED = "Maintenance_ClusterEnterMaintenanceCompleted"
DE_CLUSTER_MAINTENANCE_FAILED = "Maintenance_ClusterEnterMaintenanceFailed"

DE_CLUSTER_QUIT_MAINTENANCE_COMPLETED = "ClusterCreationCompleted"
DE_CLUSTER_QUIT_MAINTENANCE_FAILED = "Maintenance_ClusterQuitMaintenanceFailed"

DE_CLUSTER_SUSPEND_COMPLETED = "Maintenance_ClusterSuspendCompleted"
DE_CLUSTER_SUSPEND_FAILED = "Maintenance_ClusterSuspendFailed"

DE_CLUSTER_RESUME_COMPLETED = "Maintenance_ClusterResumeCompleted"
DE_CLUSTER_RESUME_FAILED = "Maintenance_ClusterResumeFailed"

def run_cdp_command(command):
    """
    Runs a CDP CLI command and returns the output as a dictionary.
    """
    try:
        result = subprocess.run(
            command, capture_output=True, text=True, check=True
        )
        return json.loads(result.stdout)
    except subprocess.CalledProcessError as e:
        print(f"Error executing command: {e.stderr}")
        return None

def suspend_resume_service(cluster_id, step, profile_name):
    print(f"Initiating {step} operation for the cluster: {cluster_id}...")
    command = [
        "cdp", "de", "suspend-resume-service",
        "--cluster-id", cluster_id,
        "--step", step,
        "--profile", profile_name
    ]
    response = run_cdp_command(command)
    print(json.dumps(response, indent=2))
    if response:
        print(f"{step} operation initiated for cluster: {cluster_id}")
        return response.get("status")
    else:
        print(f"Failed to initiate {step} operation.")
        return None

def check_cluster_status(cluster_id, success_state, failed_state, profile_name):
    """
    Checks the status of the cluster until it is succeeded or failed.
    """
    while True:
        command = [
            "cdp", "de", "describe-service",
            "--cluster-id", cluster_id,
            "--profile", profile_name
        ]
        response = run_cdp_command(command)

        if response:
            status = response.get("service").get("status")
            print(f"Cluster Status: {status}")
            if status == success_state:
                print("Cluster operation successfully complete.")
                break
            elif status == failed_state:
                print("Cluster operation failed.")
                sys.exit(1)
                break
            else:
                print("Cluster operation in progress.")
        else:
            print("Failed to fetch cluster status.")

        time.sleep(30)  # Wait for 30 seconds before checking again

def suspend_service(cluster_id, profile_name):
    #Enter-maintenance
    cluster_status = suspend_resume_service(cluster_id, "PREPARE", profile_name)
    print(f"cluster status: {cluster_status}")
    #Check the status of the cluster if maintenance is completed successfully
    if cluster_status:
       check_cluster_status(cluster_id, DE_CLUSTER_MAINTENANCE_COMPLETED, DE_CLUSTER_MAINTENANCE_FAILED, profile_name)
    else:
       sys.exit(1)

    #Suspend the cluster
    cluster_status = suspend_resume_service(cluster_id, "SUSPEND", profile_name)
    #Check the status of the cluster if suspension is completed successfully
    if cluster_status:
        check_cluster_status(cluster_id, DE_CLUSTER_SUSPEND_COMPLETED, DE_CLUSTER_SUSPEND_FAILED, profile_name)
    else:
       sys.exit(1)

def resume_service(cluster_id, profile_name):
    # Resume the cluster
    cluster_status = suspend_resume_service(cluster_id, "RESUME", profile_name)
    # Check the status of the cluster if resume is completed successfully
    if cluster_status:
        check_cluster_status(cluster_id, DE_CLUSTER_RESUME_COMPLETED, DE_CLUSTER_RESUME_FAILED, profile_name)
    else:
        sys.exit(1)

    # Quit-maintenance
    cluster_status = suspend_resume_service(cluster_id, "QUIT", profile_name)

    # Check the status of the cluster if maintenance is completed successfully
    if cluster_status:
        check_cluster_status(cluster_id, DE_CLUSTER_QUIT_MAINTENANCE_COMPLETED, DE_CLUSTER_QUIT_MAINTENANCE_FAILED,
                             profile_name)
    else:
        sys.exit(1)

if __name__ == "__main__":
    # Set up argument parsing
    parser = argparse.ArgumentParser(description='Suspend and Resume the cluster using cdpcli.')
    parser.add_argument('--cluster_id', type=str, help='The ID of the cluster.')
    parser.add_argument('--operation', type=str, help='Operation type(suspend/resume).')
    parser.add_argument('--profile', type=str, help='The name of the profile.')

    # Parse arguments
    args = parser.parse_args()
    if args.operation == "suspend":
        suspend_service(args.cluster_id, args.profile)
    elif args.operation == "resume":
        resume_service(args.cluster_id, args.profile)
    else:
        print(f"Invalid choice: operation could only be suspend or resume")
