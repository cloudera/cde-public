# CDE CLI Demo

The [Cloudera Data Engineering Experience](https://www.cloudera.com/products/data-engineering.html) (CDE) provides 3 interfaces to users:  a UI-based web frontent, a REST API, and a command-line interface (CLI).  The examples in this repository focus on some of the commonly used CLI functions.  The examples also incorporate unique features of CDE, such as Job definitions, and file-based as well as PythonEnv-based Resource definitions as dependencies for the Jobs.

While the CDE web UI can be useful to explore CDE, most developers will appreciate the CDE CLI's broad set of features to support automation and monitoring of their Data Engineering pipelines.  The CDE CLI also has minimal dependencies (relies only on CDE's REST API) and can therefore be configured on any host with web access to the CDE virtual cluster endpoint.

####
Pre-requisites for the CLI examples:
- The CDE CLI is configured in the user's environment.  See these instructions, for reference:  https://docs.cloudera.com/data-engineering/cloud/cli-access/topics/cde-cli.html
- The user has completed the first 2 jobs ('ingest' and 'enrich') jobs from the [CDE workshop examples](https://github.com/curtishoward/cde_etl_demo) (the examples below will leverage the Hive databases/tables created by those jobs).  __**Alternatively**__, use run the included Spark job to create a simple test table:  ```cde spark submit setup_table.py```

## cde spark submit
The CDE CLI command ```cde spark submit``` will be very familiar to developers migrating Spark applications from ```spark-submit``` - this is often the best place to start when testing an existing application in CDE.

For a list of suggested changes when migrating Spark applications from `spark-submit` (and Spark-on-YARN) to `cde spark submit` (CDE/Spark-on-k8s), please review the following [spark-submit-2-cde-spark-submit](./spark-submit-2-cde-spark-submit.md) notes.

As an example, the commands below will create a zip archive of custom Python code (a UDF definition in this case), and then submit the job the CDE virtual cluster:
<br/>
```
zip -r simple_udf.zip demo_utils/__init__.py demo_utils/simple_udf.py
cde spark submit simple_udf_dependency.py \
    --py-file simple_udf.zip \
    --conf spark.executorEnv.PYTHONPATH=/app/mount/simple_udf.zip \
    --job-name simple-udf-test
```

It's important to remember than all CDE workloads (Spark driver and executor processes, Airflow DAG configuration, etc) run within the CDE service resources (Kubernetes cluster).  All CDE CLI commands (such as ```cde spark submit```) only interact with CDE service metadata (e.g. to trigger a job, monitor it, delete a resource, update an Airflow DAG configuration, etc).  Importantly, the local resource requirements for the CDE CLI binary itself should be minimal (and independent from) resource requirements of your actual workkload.

## Job monitoring
The CDE CLI provides options under ```cde run ...``` and ```cde logs ...``` sub-commands to monitor and collect logs for Job Runs.  As an example, we can use the following command to locate the Job Run that just completed.  Additional filters can be added to the command - see the ```cde run list -h``` help section and also REST API documentation link from the virtual cluster web UI details page:
<br/>
```cde run list --filter job[rlike]
  {
    "id": 6,
    "job": "simple-udf-test",
    "type": "spark",
    "status": "succeeded",
    "user": "curtis",
 ...
 ```
We can then use the ```cde run logs``` command inspect the logs for the Job run - in this case we'll use an option to download all logs locally for further inspection:
<br/>
```
cde run logs --id 6 --download-all
```

## Jobs, Resources, Python environments
CDE provides powerful built-in features which allow for both centralized management of Resources that are shared between Jobs as well as dependency isolation between jobs.  There are 3 types of CDE Resources:
1. **files**:  Essentially any files that you would like to make accessible to your application (plaintext configuration files, JARs, zip archives (for example, of Python source), Python .egg files).  The resource can then be mounted under a specific path that you choose (See example below)
2. **python-env**:  Python environments are defined by a requirements.txt file (similar to the way you would define an Anaconda Python environment).  This allows applications to run with independent Python package versions.  This feature also supports PyPi servers/mirrors that your organization may be using to host internal/custom packages.
3. **custom-runtime-image**:  It is also possible to create a custom image (typically using the CDE Spark Docker image as a base).  Your application will be launched using the custom Docker image specified.  This feature is currently released as a 'tech-preview', and not covered in the examples below. In almost all cases you should aim to use the other available resource types.
4. _Maven coordinates_ - while not a CDE Resource that you would defineon in your virtual cluster, you can also use the```--repositories``` option (part of ```cde spark submit``` and ```cde job create``` commands) to include specific Maven packages.


As an example, we will create a **python-env** Resource that includes a specific Python package (defined in [requirements.txt](requirements.txt)) required by our next sample application:
```
cde resource create --name cde-cli-penv-resource --type python-env --python-version python3
cde resource upload --local-path requirements.txt --name cde-cli-penv-resource
```
The CDE cluster will then build the environment in the background - you can check the status of the build from the CLI as follows (or from the UI):
```
cde resource list --filter name[rlike]cde-cli-demo-resource
[
  {
    "name": "cde-cli-demo-resource",
    "type": "python-env",
    "status": "building",
...
```
Once our **python-env** Resource status changes to _ready_, it can be referenced by job defitions.
First though, we will create a second resource containing another Pyhton UDF function (this time, one that depends on the package specified in the **python-env** Resource we just created):
```
cde resource create --name cde-cli-files-resource --type files --python-version=python3
zip -r deps_udf.zip demo_utils/__init__.py demo_utils/deps_udf.py
cde resource upload --name cde-cli-files-resource --local-path ./deps_udf_dependency.py --local-path ./deps_udf.zip
```
We're now ready to create the job, which depends on the UDF code (**files** Resource that we created) and also the the specific PyPi Python package (**python-env** Resource that we also created).  Note that a _single_ **python-env** package can be specific for a job, and _multiple_ **files** Resources can be configured (under separate paths, using pairs of ```--mount-N-prefix``` / ```--mount-N-resource``` options):
```
cde job create --name penv-udf-test --type spark \
               --mount-1-prefix appFiles/ \
               --mount-1-resource cde-cli-files-resource \
               --python-env-resource-name cde-cli-penv-resource \
               --application-file /app/mount/appFiles/deps_udf_dependency.py \
               --conf spark.executorEnv.PYTHONPATH=/app/mount/appFiles/deps_udf.zip \
               --py-file /app/mount/appFiles/deps_udf.zip
```
At this point we can trigger the job that we defined, as follows:
```
cde job run --name penv-udf-test
```

## Airflow
As a final CDE CLI example, we'll create another job of type **airflow**.  Our Airflow DAG will simply trigger the Spark CDE Job that just defined (_penv-udf-test_) using the built-in CDEJobRunOperator.  CDE **airflow** Jobs allow developers to access Airflow's rich set of scheduling features from the managed Airflow sub-service provided with each of your CDE virtual clusters.  For example, the DAG that we use below ([airflow_dag.py](airflow_dag.py)) makes use of the Airflow Task ```execution_timeout``` option to kill the Task (our CDE Job, in this case), if it does not complete within the specified SLA.

Similar to **spark** Jobs in CDE, an **airflow** job can be submitted as a 1-time run using ```cde airflow submit``` (the DAG will be automatically deleted from CDE's managed Airflow sub-service, once complete):
```
cde airflow submit airflow_dag.py --job-name test-airflow-submit

```
To create a permanent CDE Airflow Job for the same DAG:
```
cde resource create --name airflow-files-resource
cde resource upload --name airflow-files-resource --local-path ./airflow_dag.py
cde job create --name airflow-job --mount-1-resource airflow-files-resource --dag-file  airflow_dag.py --type airflow
cde job run --name airflow-job
```

