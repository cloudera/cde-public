# cde spark submit (Spark-on-YARN -> CDE/Spark-on-k8s)

The [CDE CLI](https://docs.cloudera.com/data-engineering/cloud/cli-access/topics/cde-cli.html) ```cde spark submit``` command is intended to closely match Apache Spark's ```spark-submit``` command:

```
Usage:
  cde spark submit [flags]

Examples:
Local job file 'my-spark-app-0.1.0.jar' and Spark arguments '100' and '1000':
> cde spark submit my-spark-app-0.1.0.jar 100 1000 --class com.company.app.spark.Main

Remote job file:
> cde spark submit s3a://my-bucket/my-spark-app-0.1.0.jar 100 1000 --class com.company.app.spark.Main


Flags:
      --class string                         job main class
      --conf stringArray                     Spark configuration (format key=value) (can be repeated)
      --driver-cores int                     number of driver cores
      --driver-memory string                 driver memory
      --executor-cores int                   number of cores per executor
      --executor-memory string               memory per executor
      --file stringArray                     additional file (can be repeated)
  -h, --help                                 help for submit
      --hide-logs                            whether to hide the job run logs from the output
      --initial-executors string             initial number of executors
      --jar stringArray                      additional jar (can be repeated)
      --job-name string                      name of the generated job
      --log-level string                     Spark log level (TRACE, DEBUG, INFO, WARN, ERROR, FATAL, OFF)
      --max-executors string                 maximum number of executors
      --min-executors string                 minimum number of executors
      --packages string                      additional dependencies as list of Maven coordinates
      --py-file stringArray                  additional Python file (can be repeated)
      --pypi-mirror string                   PyPi mirror for --python-requirements
      --python-env-resource-name string      Python environment resource name
      --python-requirements string           local path to Python requirements.txt
      --python-version string                Python version ("python3" or "python2")
      --repositories string                  additional repositories/resolvers for --packages dependencies
      --runtime-image-resource-name string   custom runtime image resource name
      --spark-name string                    Spark name
```

Still, there are differences in command syntax, and also functional differences between CDE/Spark-on-k8s and Spark-on-YARN that you should be aware of.  While not an exhaustive guide to converting your Spark-on-YARN (CDH/HDP/Datahub) application to CDE/Spark-on-k8s, the sections below cover some of the common configuration changes that will be required.

## Remove
To start, the following options that you may have used with `spark-submit` should be **__removed__** when using CDE (e.g. `cde spark submit`):
- drop `--master` : this is set internally by CDE.
- drop `--deploy-mode` : this will essentially always be `cluster` mode - internally set by CDE.
- drop `--spark.keytab`, `--spark.yarn.principal`, etc: Kerberos authentication details handled internally by CDE, based on your CDP workload user's authentication.
- drop `shuffle.service.enabled=true` : external shuffle service is actively being developed by Cloudera for Spark-on-k8s (available in an upcoming release)

## Update
- `spark-submit`'s `--files` and `--py-files` comma-separated syntax must be replaced with multiple `--file` / `py-file` entries.  For example:
  ```
  --files f1.txt,f2.txt
  
  becomes
  
  --file f1.txt --file f2.txt
  ```
- **IMPORTANT** : by default, files included with job configuration (e.g. `--file some_file.txt`) will be available under `/app/mount/some_file.txt` (and not the Spark process working directory).  Therefore the application will need to refer to this full path to access the file (rather than `./some_file.txt`).
- If the application/entrypoint itself needs to be passed additional arguments, these should be separated from the `cde spark submit` arguments using `--` in front of them. This will instruct the parser to treat the rest of the string literally, e.g.:
    ```
    my_entrypoint.py -- -a 1 -b "twenty two"
    ```
* Rename `--app.name` to `--job-name`
* CDE defaults to Python3.  If you intend to use legacy Python2, Add `--python-version python2`.  The Python version should always be set through CDE (for example, `--python-version` flag).  Any previous references used to set the Python version (such as `spark.yarn.appMasterEnv.PYSPARK_PYTHON=python3.6`) should be removed.
* If you are migrating an application from an on-prem environment that uses HDFS for storage, you will also likely need to update `hdfs://...` paths in your configuration to the equivalent cloud storage URI of that data (for example, `s3a://...`)
* 


## Review
- There are a number of [YARN-specific Spark configurations](https://spark.apache.org/docs/3.1.1/running-on-yarn.html#spark-properties) that will need to be reviewed and either removed or converted to [Spark-on-k8s specific configuration](https://spark.apache.org/docs/3.1.1/running-on-kubernetes.html#configuration). The references linked to are specific to Spark 3.1.1.
- In some cases (such as `spark.yarn.executor.memoryOverhead`), Spark now provides more agnostic configuration that can be used (e.g. `spark.executor.memoryOverhead`).
- In other cases, you can use the k8s configuration that is equivalent, for example (setting environment variables for the Spark processes):
```
spark.yarn.appMasterEnv.TZ=America/Los_Angeles

becomes

spark.kubernetes.driverEnv.TZ=America/Los_Angeles
```
- Keep in mind that certain Spark-on-k8s configuration listed in the reference links above may not apply or be compatible with CDE (often CDE manages those, or their equivalents internally - for example, configuration related to k8s namespaces, authentication, or volume mounts).  **Please reach out to Cloudera support or your Cloudera account team if you have questions on this part of your migration**.
- Configuration related to external/3rd-party vendor products should be reviewed and possibly removed (one example of this: Unravel Data configuration such as `spark.unravel.*`)

## CDE Resources
Finally, CDE introduces the concept of [Resources](https://docs.cloudera.com/data-engineering/cloud/use-resources/topics/cde-python-virtual-env.html) to manage shared sets of files (JARs, zip, text/config files) as well as Python Environments.  In other Spark environments, files may have been pre-populated, or Python packages installed through `pip`, Anaconda, or similar.  'Resources' replace these concepts in CDE.  This is a good point to return to the [main article](https://github.com/curtishoward/CDE_CLI_demo/blob/master/README.md), which provides examples of using both file-based and Python environment CDE Resources from a CDE Spark application.




