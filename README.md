# Scality COSI + CSI drivers on VMware VKS — functional test harness

Installs the Scality **COSI driver** (and, opt-in, the Scality **CSI Driver for S3**) on a VMware vSphere Kubernetes Service (VKS) cluster, runs functional tests against a Scality RING S3 endpoint, and collects the evidence.

It runs from any host with `kubectl` access to the cluster (cluster-admin). It pauses where a screenshot is useful and tells you what to capture.

## Quick start

```bash
git clone <this repo> && cd <this repo>
./run.sh                 # asks once for: S3 endpoint URL, access key, secret key, region
```

The keys are stored in `~/.vks-test.env` (mode 600). They never go into the results and are never uploaded.

| Command | What it does |
|---|---|
| `./run.sh` | All COSI phases, starting at `preflight` |
| `./run.sh --with-csi` | Also run the CSI phases. They are excluded by default: on RING 9.5.3 the CSI driver cannot list objects ([scality/mountpoint-s3-csi-driver#387](https://github.com/scality/mountpoint-s3-csi-driver/issues/387)) |
| `./run.sh --from cosi-test` | Resume from a phase, e.g. after refreshing an expired kube token |
| `./run.sh --only cosi-test` | One phase only |
| `./run.sh --yes` | No screenshot pauses |
| `./run.sh --cleanup` | Remove drivers, test namespaces and test buckets (the results bucket is kept) |
| `./run.sh --reset-config` | Enter the endpoint and keys again |

## Phases and tests

| Phase | ID | Test |
|---|---|---|
| preflight | PF-1 | Kubernetes ≥ 1.30 (CSI 2.x requirement) |
| | PF-2 | cluster-admin rights |
| | PF-3 | Host egress to ghcr.io, gcr.io, github.com, public.ecr.aws and the S3 endpoint |
| | PF-4/5 | `git` present; `helm` present (installed to `~/.local/bin` if missing) |
| | PF-6 | From a pod: registries reachable, S3 list/create/delete and IAM list-users work with the account keys |
| cosi-install | CI-1 | COSI controller + CRDs (`v0.2.2`, v1alpha1) and Scality COSI driver `1.0.2` running |
| cosi-test | CT-1 | BucketClaim → bucket created on RING |
| | CT-2 | BucketAccess → IAM user + credentials Secret (BucketInfo) |
| | CT-3 | The application pod published in the reference architecture (`doc-snippets/app-pod.sh`, run verbatim) writes, lists and reads back an object using only the COSI-issued credentials |
| | CT-3b | A 1 MiB object written, listed, read back and checksummed with the COSI-issued credentials |
| | CT-4 | A second namespace gets its own bucket; the published isolation check (`doc-snippets/isolation-pod.sh`, run verbatim) is denied on the first bucket |
| | CT-5 | Deleting the BucketAccess removes its Secret and revokes the keys |
| | CT-6 | `deletionPolicy: Delete` removes the (empty) bucket with its claim |
| | CT-7 | `deletionPolicy: Retain` keeps the bucket after its claim is deleted |
| csi-install (`--with-csi`) | SI-1 | Scality CSI Driver for S3 `2.2.0` running (node DaemonSet + controller) |
| csi-test (`--with-csi`) | CS-1 | Static PV/PVC on a pre-created bucket; pod writes files |
| | CS-2 | A second pod reads the same volume (ReadWriteMany), checksums match |
| | CS-3 | Files written through CSI are plain S3 objects with matching checksums |
| | CS-4 | Data persists for a new pod after the first pods are deleted |
| | CS-5 | Dynamic provisioning: StorageClass creates a bucket; write/read via CSI and S3 |
| | CS-6 | `reclaimPolicy: Delete` removes the (empty) bucket with its PVC |
| collect | CO-1 | Results tarball uploaded to `s3://vks-<run>-results/` |

Results land in `/mnt/scality/vks-results/<run>/` (or `~/vks-results/<run>/`) and contain:
- `SUMMARY.txt`
- `summary.tsv`
- `screenshots.tsv` (what to capture, and the file names)
- `evidence/` (every command and its output)
- `manifests/` (every applied object; Secrets excluded)

## Published snippets

`doc-snippets/` holds byte-for-byte copies of the commands published in the reference architecture. `run.sh` runs them as they are, only renaming the example namespaces and Secrets to this run's names, so a passing CT-3 and CT-4 prove the published steps work. Edit the document first, then re-copy the snippet.

## Cleanup

`--cleanup` deletes application pods, then BucketAccesses, then BucketClaims while the COSI controller and driver are still running, because their finalizers can only be cleared by them. If any remain, it stops before uninstalling the driver and tells you what is left.

## Kubernetes objects created

| Namespace | Pod Security | Contents |
|---|---|---|
| `container-object-storage-system` | privileged | COSI controller + Scality COSI driver (the driver pod sets no securityContext) |
| `scality-s3-csi` | privileged | CSI node DaemonSet (privileged, FUSE) + controller |
| `mount-s3` | restricted | Mountpoint pods (created by the CSI chart) |
| `vks-tools`, `vks-cosi-a`, `vks-cosi-b`, `vks-csi` | cluster default | Test pods. They comply with the `restricted` profile |

Cluster-scoped objects: `vks-<run>-del` / `-ret` (BucketClass), `vks-<run>-bac` (BucketAccessClass), `vks-<run>-s3` (StorageClass) and `vks-<run>-static-pv`. Every bucket name starts with `vks-<run>-`, except dynamically provisioned CSI buckets (`csi-s3-<uuid>`) and COSI buckets (`<class-name><uuid>`).

## Images pulled

- `ghcr.io/scality/cosi-driver:1.0.2`
- `gcr.io/k8s-staging-sig-storage/objectstorage-sidecar:v20241219-v0.1.0-60-g6a5a12c`
- `gcr.io/k8s-staging-sig-storage/objectstorage-controller:*` (from the COSI controller manifests)
- `ghcr.io/scality/mountpoint-s3-csi-driver:2.2.0` plus its sidecars under `ghcr.io/scality/mountpoint-s3-csi-driver/`
- `public.ecr.aws/aws-cli/aws-cli:2.17.0` (test pods; override with `TEST_IMAGE=`)

The COSI CRDs and controller are applied with `kubectl apply -k github.com/kubernetes-sigs/container-object-storage-interface//?ref=v0.2.2`, which needs `git` and access to github.com.

## Overrides (environment variables)

`COSI_CHART_VERSION`, `COSI_CONTROLLER_REF`, `CSI_CHART_VERSION`, `TEST_IMAGE`, `HELM_VERSION`, `WAIT` (default `300s`), `CONFIG_FILE`.

## References

- COSI driver: https://github.com/scality/cosi-driver
- CSI Driver for S3: https://github.com/scality/mountpoint-s3-csi-driver
- Kubernetes COSI: https://github.com/kubernetes-sigs/container-object-storage-interface
