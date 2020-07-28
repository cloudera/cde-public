# CDE Diagnostics Tool

This script simplifies the collection of diagnostic data from running CDE services and virtual clusters. Currently it can
collect the following information:

* Kubernetes statuses for core CDE components and virtual clusters
* Kubernetes logs for all CDE pods, excluding Spark pods

Planned additions:

* Collecting archived logs from object storage
* Composing all collections into a diagnostic bundle which can be shared with Cloudera Support

*Note*: This script is a temporary solution while we build a full diagnostics collection capability into the product.

## Prerequisites

### Core program requirements

The following programs must be on the `PATH` when running the script:

* `which`
* `python`
* `curl`
* `tar`

### AWS 

### Additional AWS program requirements

* `groff` (for AWS CLI)
* `unzip` (for AWS CLI)

#### Authentication to EKS

The script will require an AWS IAM user with programmatic access (an access key ID and a secret key). The user
must have appropriate access to the EKS cluster. Currently the only supported method is to add the user as a 
"Trusted Entity" on the admin role which was used to create the CDE service. This
is the cross-account role that was used when setting up your CDP environment. To add the IAM user:

* Go to the AWS IAM console, then navigate to "Users"
* Find and select the user and copy and paste its ARN value
* Go to the AWS IAM console, then navigate to "Roles" 
* Find and select the cross-account role and click the "Trust relationships" tab
* Click "Edit trust relationship"
* Add the following snippet to the JSON, replacing `<USER_ARN>` with the user's ARN copied above
```
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "<USER_ARN>"
      },
      "Action": "sts:AssumeRole"
    }
```
* Note the role ARN of the cross-account role. You will need to supply this during diagnostics collection

[comment]: # TODO -- add instructions for admin users added via Control Plane API

#### Access to EKS

Depending on where you want to run the diagnostics script, you may need to grant additional access to the
EKS Kubernetes API server. If running the script on an instance in the same VPC as the EKS cluster, you
will need to add the instance internal IP (or a containing CIDR range) to the "Cluster security group" 
for the EKS cluster. 

To do this, head to the AWS console and select the correct EKS cluster (the "liftie-" ID can be found in
the logs on the CDE environment details page—look for "Cluster provisioner ID:"). Under the "Networking"
tab select the "Cluster security group" and add an inbound rule from the EC2 instance. You can allow
all traffic or limit it to HTTPS.

### Kubeconfig

To interact with the Kubernetes cluster we require a `kubeconfig` file. This can be obtained for the CDE
service in question via the CDE Management Console. For the CDE service you want to collect diagnostics
for select "Download Kube Config" from the drop-down menu at the top right.

Copy or paste the contents of the file into a file on the system where you wish to run CDE diagnostics.

## Installation

Currently the easiest way to install the tool is to download a release from the temporary Github repo:

https://github.com/ianbuss/cde-diagnostics

Once the release has been expanded, the script can be bootstrapped as follows:

```
./cde_diagnostics install
```

This will download and install a number of useful tools including `kubectl` and `awscli`, together with
their ancillary requirements. All installation and configuration is isolated to a `tools` sub-directory 
in the same location as the script.

During the bootstrap process an AWS user is configured. This user should have the ability to perform
`AssumeRole` to the core EKS admin role as specified above.

## Printing CDE component status

To gather the statuses of all CDE components running in the Kubernetes cluster, run the following:

```
./cde_diagnostics -r <ROLE_ARN> -k <KUBECONFIG_FILE> status
```

This will print all the status information for both base CDE components running in the `dex` namespace
and that of the service pods in the virtual clusters. For extended information add either `-f yaml` or
`-f json` to the command.

## Gathering CDE component logs

The following command will capture logs from all containers in all running CDE pods, *except running Spark 
and Airflow worker pods*:

```
./cde_diagnostics -r <ROLE_ARN> -k <KUBECONFIG_FILE> logs
```

The quantity of output is often large, so it is recommended to pipe this to an output file for review. To limit
the file size the file can be compressed as follows:

```
./cde_diagnostics -r <ROLE_ARN> -k <KUBECONFIG_FILE> logs | gzip > /tmp/logoutput.gz
```