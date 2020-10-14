# CDE Diagnostics Tool

This script simplifies the collection of diagnostic data from running CDE services and virtual clusters. Currently it can
collect the following information:

* Status of all AWS cloud resources created during CDE provisioning
* Kubernetes statuses for core CDE components and virtual clusters
* Kubernetes logs for all CDE pods, excluding Spark pods
* Composing above into a compressed diagnostic bundle 

Planned additions:

* Collecting archived logs from object storage

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
must have appropriate access to the EKS cluster. 

This means the user ARN has been added as an admin in the "Access" tab of the environment details in the CDE
management console.

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

You can use the diagnostics tool from your own Linux machine or setup a Docker Linux container as documented below.

### Setup Linux Docker Container (optional)

The following are basic instructions for setting up a Docker CentOS Linux image. You can also run the script on a standard Linux host, but the following dockerfile ensures the script's prerequisites are met.

1. Create docker workspace in a directory of your choice.

    ```
    mkdir diagnostics
    cd diagnostics
    touch Dockerfile
    ```

1. Paste the following into "Dockerfile" and save it.

   ```
   FROM centos:centos8

   RUN yum install -y unzip which python36
   RUN ln -s /usr/bin/python3 /usr/bin/python
   RUN curl -LO http://mirror.centos.org/centos/7/os/x86_64/Packages/groff-1.22.2-8.el7.x86_64.rpm
   RUN curl -LO http://mirror.centos.org/centos/7/os/x86_64/Packages/groff-base-1.22.2-8.el7.x86_64.rpm
   RUN rpm -i groff-base-1.22.2-8.el7.x86_64.rpm
   RUN rpm -i groff-1.22.2-8.el7.x86_64.rpm
   ```

1. Build and run the Docker image

   ```
   export DIAGNOSTICS_IMAGE_TAG=cloudera/cde_diagnostics
   # build it
   docker build -t $DIAGNOSTICS_IMAGE_TAG .
   # run it
   docker run -it $DIAGNOSTICS_IMAGE_TAG /bin/bash
   ```

1. You should now have a shell into the Linux container from which to execute the CDE diagnostic commands. The next section details instructions for obtaining the diagnostic script and executing commands from your Linux host.

### Tool Installation

This step assumes you are running on a Linux host or container with the aforementioned tool prerequisites. Currently the easiest way to install the tool is to download a release from the public Github repo:

```
cd ~
# be sure to copy/paste your CDE service's kubeconfig in this file
touch kubeconfig
curl -LO https://raw.githubusercontent.com/cloudera/cde-public/master/diagnostics/cde_diagnostics
chmod u+x cde_diagnostics
```

Note: This tool is setup for Helm 3. If you are on an older version of CDE (<=1.0.1), you should modify the `HELM_VERSION` env var in `cde_diagnostics` and set it to `2.14.2`.

Once the script has been downloaded, the script can be bootstrapped as follows:

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
./cde_diagnostics -k <KUBECONFIG_FILE> status
```

This will print all the status information for both base CDE components running in the `dex` namespace
and that of the service pods in the virtual clusters. For extended information add either `-f yaml` or
`-f json` to the command.

## Gathering CDE component logs

The following command will capture logs from all containers in all running CDE pods, *except running Spark 
and Airflow worker pods*:

```
./cde_diagnostics -k <KUBECONFIG_FILE> logs
```

The quantity of output is often large, so it is recommended to pipe this to an output file for review. To limit
the file size the file can be compressed as follows:

```
./cde_diagnostics -k <KUBECONFIG_FILE> logs | gzip > /tmp/logoutput.gz
```

If using the Docker container as described above, you can copy the logs locally as follows:

```
# Find your container ID
docker ps --filter "ancestor=$DIAGNOSTICS_IMAGE_TAG"
# Use the container ID in the copy command
docker cp <CONTAINER ID>:/tmp/logoutput.gz .
```

