**Hadoop core-site.xml patch script to fix RAZ signer parameters if we see error org.apache.hadoop.fs.s3a.impl.InstantiationIOException while running the jobs** 


A helper script to safely **modify and restore Hadoop configuration stored in a Kubernetes ConfigMap**

The script automates:
- Backing up the original ConfigMap  
- Decoding and editing `core-site.xml`  
- Removing legacy S3 signer properties  
- Adding Ranger RAZ-based S3 signer configuration  
- Patching the cluster ConfigMap  
- Optionally restoring the backup if needed  

---

## Features

✅ **Backup** the original ConfigMap to a local YAML file  
✅ **Removes** old properties:
- `fs.s3a.custom.signers`
- `fs.s3a.s3.signing-algorithm`
✅ **Adds** new RAZ signer configuration:
- `fs.s3a.http.signer.class=org.apache.ranger.raz.hook.s3.RazS3SignerPlugin`
- `fs.s3a.http.signer.enabled=true`
✅ **Restores** ConfigMap from backup on demand  
✅ **Validates** dependencies (`kubectl`, `jq`, `xmlstarlet`, `base64`)

---

## Prerequisites

You must have these tools installed:

```bash
kubectl
jq
xmlstarlet
base64
```
**Usage**
```bash 
./patch_hadoop_conf.sh [command] [namespace]
```
**Commands**
| Command | Description |
|:---|:---:|
|run_test|Backs up the ConfigMap, modifies core-site.xml, and patches the cluster
|restore|Restores the original ConfigMap from the local backup

**Example**
Apply patch
```bash 
./patch_hadoop_conf.sh run_test dex-app-c59x5d57
```
This will:
Back up clientconfigs-default-hadoop-conf in the namespace dex-app-c59x5d57
Remove outdated S3 signer properties
Add new Ranger RAZ signer settings
Patch the updated ConfigMap back into the cluster

**Restore backup**
```bash
./patch_hadoop_conf.sh restore dex-app-c59x5d57 
```
This re-applies the original YAML backup (clientconfigs-default-hadoop-conf.original.yaml).