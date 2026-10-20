#!/usr/bin/env bash
# Scality COSI + CSI drivers on VMware vSphere Kubernetes Service (VKS) — functional test harness.
#
# Usage:
#   ./run.sh                    run every phase from preflight (COSI only)
#   ./run.sh --with-csi         also run the CSI phases (excluded by default: scality/mountpoint-s3-csi-driver#387)
#   ./run.sh --from cosi-test   resume from a phase (e.g. after a token refresh)
#   ./run.sh --only cosi-test   run one phase
#   ./run.sh --yes              no screenshot pauses
#   ./run.sh --cleanup          remove everything this harness created (results bucket kept)
#   ./run.sh --reset-config     ask for endpoint and keys again
#
# Phases: preflight cosi-install cosi-test [csi-install csi-test] collect
set -uo pipefail

# ---------------------------------------------------------------- settings
COSI_CONTROLLER_REF="${COSI_CONTROLLER_REF:-v0.2.2}"   # v1alpha1; upstream main is v1alpha2 and incompatible
COSI_CHART_VERSION="${COSI_CHART_VERSION:-1.0.2}"
COSI_CHART="oci://ghcr.io/scality/cosi-driver/helm-charts/scality-cosi-driver"
COSI_NS="container-object-storage-system"
CSI_CHART_VERSION="${CSI_CHART_VERSION:-2.2.0}"
CSI_CHART="oci://ghcr.io/scality/mountpoint-s3-csi-driver/helm-charts/scality-mountpoint-s3-csi-driver"
CSI_NS="scality-s3-csi"
TEST_IMAGE="${TEST_IMAGE:-public.ecr.aws/aws-cli/aws-cli:2.17.0}"
HELM_VERSION="${HELM_VERSION:-v3.16.4}"
TOOLS_NS="vks-tools"
NS_COSI_A="vks-cosi-a"
NS_COSI_B="vks-cosi-b"
NS_CSI="vks-csi"
WAIT="${WAIT:-300s}"

CONFIG_FILE="${CONFIG_FILE:-$HOME/.vks-test.env}"
PHASES=(preflight cosi-install cosi-test collect)
CSI_PHASES=(csi-install csi-test)   # opt-in with --with-csi
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$HOME/.local/bin:$PATH"

# ---------------------------------------------------------------- output helpers
c_b=$'\e[1m'; c_g=$'\e[32m'; c_r=$'\e[31m'; c_y=$'\e[33m'; c_0=$'\e[0m'
say()  { printf '%s\n' "${c_b}==> $*${c_0}"; }
warn() { printf '%s\n' "${c_y}WARN: $*${c_0}"; }
die()  { printf '%s\n' "${c_r}ERROR: $*${c_0}" >&2; exit 1; }

# ev <name> <cmd...>: run a command, show it, save command + output to the results dir.
ev() {
  local name="$1"; shift
  local f="$RES/evidence/${CUR_PHASE}--${name}.txt"
  { printf '$ %s\n' "$*"; "$@" 2>&1; } | tee "$f"
  return "${PIPESTATUS[0]}"
}

# result <id> <PASS|FAIL|SKIP> <text>
result() {
  local id="$1" st="$2"; shift 2
  local col="$c_g"; [[ $st == FAIL ]] && col="$c_r"; [[ $st == SKIP ]] && col="$c_y"
  printf '%s\n' "${col}[$st]${c_0} $id — $*"
  # replace an earlier line for the same id (re-runs)
  grep -v "^$id	" "$RES/summary.tsv" > "$RES/summary.tsv.tmp" 2>/dev/null || true
  printf '%s\t%s\t%s\t%s\n' "$id" "$st" "$*" "$(date -u +%FT%TZ)" >> "$RES/summary.tsv.tmp"
  mv "$RES/summary.tsv.tmp" "$RES/summary.tsv"
}

# shot <file> <what to capture>: pause for a laptop-side screenshot.
shot() {
  local file="$1"; shift
  printf '%s\t%s\n' "$file" "$*" >> "$RES/screenshots.tsv"
  (( YES )) && { echo "  (screenshot point skipped: $file — $*)"; return 0; }
  printf '\n%s\n' "${c_y}┌─ SCREENSHOT ─────────────────────────────────────────────${c_0}"
  printf '%s\n' "${c_y}│${c_0} Save as: ${c_b}$file${c_0}"
  printf '%s\n' "$*" | fold -s -w 70 | sed "s/^/${c_y}│${c_0} /"
  printf '%s\n' "${c_y}└──────────────────────────────────────────────────────────${c_0}"
  read -r -p "Press Enter when done (or type 'skip'): " ans
  [[ $ans == skip ]] && sed -i "s|^$file\t|$file (skipped)\t|" "$RES/screenshots.tsv"
  return 0
}

# ---------------------------------------------------------------- config
load_config() {
  if [[ ! -f $CONFIG_FILE || ${RESET_CONFIG:-0} == 1 ]]; then
    say "First run: RING S3 endpoint and keys (stored in $CONFIG_FILE, mode 600, never uploaded)"
    local ep ak sk rg
    read -r -p "S3 endpoint URL (e.g. https://s3.example.com): " ep
    read -r -p "Access key ID: " ak
    read -r -s -p "Secret access key (hidden): " sk; echo
    read -r -p "Region [us-east-1]: " rg
    [[ -n $ep && -n $ak && -n $sk ]] || die "endpoint and both keys are required"
    local rid; rid="$(tr -dc 'a-z0-9' </dev/urandom | head -c 6)"
    umask 077
    cat > "$CONFIG_FILE" <<EOF
S3_ENDPOINT='${ep%/}'
AWS_ACCESS_KEY_ID='$ak'
AWS_SECRET_ACCESS_KEY='$sk'
S3_REGION='${rg:-us-east-1}'
RUN_ID='$rid'
EOF
    chmod 600 "$CONFIG_FILE"
  fi
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  : "${S3_ENDPOINT:?}" "${AWS_ACCESS_KEY_ID:?}" "${AWS_SECRET_ACCESS_KEY:?}" "${RUN_ID:?}"
  S3_REGION="${S3_REGION:-us-east-1}"
  P="vks-$RUN_ID"                       # prefix for every bucket and class this run creates
  RESULTS_BUCKET="$P-results"
  local base=/mnt/scality/vks-results
  mkdir -p "$base" 2>/dev/null && [[ -w $base ]] || base="$HOME/vks-results"
  RES="$base/$RUN_ID"
  mkdir -p "$RES/evidence" "$RES/manifests"
  touch "$RES/summary.tsv" "$RES/screenshots.tsv"
}

# ---------------------------------------------------------------- kube helpers
check_token() {
  if ! kubectl auth can-i get pods >/dev/null 2>&1; then
    die "kubectl cannot reach the cluster (session token expired?). Refresh it per the lab manual (p. 28, vcf context), then: ./run.sh --from $CUR_PHASE"
  fi
}

# apply <name> : apply YAML from stdin, keep a copy (secrets are never passed through here)
apply() {
  local name="$1" f="$RES/manifests/${CUR_PHASE}--$1.yaml"
  cat > "$f"
  kubectl apply -f "$f"
}

ns_create() {  # ns_create <ns> [psa-level]
  kubectl create namespace "$1" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  [[ -n ${2:-} ]] && kubectl label --overwrite ns "$1" \
      "pod-security.kubernetes.io/enforce=$2" "pod-security.kubernetes.io/warn=$2" >/dev/null
  return 0
}

secret_root() {  # secret_root <ns> <name> <style:aws|cosi|csi>  — root keys, never logged
  local ns="$1" name="$2" style="$3"
  case $style in
    aws)  kubectl -n "$ns" create secret generic "$name" --dry-run=client -o yaml \
            --from-literal=AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
            --from-literal=AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" ;;
    cosi) kubectl -n "$ns" create secret generic "$name" --dry-run=client -o yaml \
            --from-literal=accessKeyId="$AWS_ACCESS_KEY_ID" \
            --from-literal=secretAccessKey="$AWS_SECRET_ACCESS_KEY" \
            --from-literal=endpoint="$S3_ENDPOINT" \
            --from-literal=iamEndpoint="$S3_ENDPOINT" \
            --from-literal=region="$S3_REGION" ;;
    csi)  kubectl -n "$ns" create secret generic "$name" --dry-run=client -o yaml \
            --from-literal=access_key_id="$AWS_ACCESS_KEY_ID" \
            --from-literal=secret_access_key="$AWS_SECRET_ACCESS_KEY" ;;
  esac | kubectl apply -f - >/dev/null
}

# Restricted-PSA-compliant pod/container security settings, shared by every test pod.
POD_SEC='  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
    seccompProfile: {type: RuntimeDefault}'
CTR_SEC='      securityContext:
        allowPrivilegeEscalation: false
        capabilities: {drop: [ALL]}'
AWS_ENV="      - {name: HOME, value: /tmp}
      - {name: AWS_EC2_METADATA_DISABLED, value: \"true\"}
      - {name: AWS_CONFIG_FILE, value: /scripts/aws-config}"

# scripts_cm <ns>: ConfigMap with the in-pod test scripts (scripts/ dir) + path-style aws config
scripts_cm() {
  kubectl -n "$1" create configmap vks-scripts --dry-run=client -o yaml \
    --from-file="$HERE/scripts" | kubectl apply -f - >/dev/null
}

wait_pod_done() {  # wait_pod_done <ns> <pod> -> 0 if Succeeded
  local ns="$1" pod="$2" i phase
  for ((i = 0; i < 100; i++)); do
    phase="$(kubectl -n "$ns" get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null)"
    [[ $phase == Succeeded ]] && return 0
    [[ $phase == Failed ]] && return 1
    sleep 3
  done
  warn "pod $ns/$pod did not finish; events:"; kubectl -n "$ns" describe pod "$pod" | tail -15
  return 1
}

# run_pod <ns> <pod> <script> [extra env yaml] [extra volumeMounts yaml] [extra volumes yaml]
# Runs scripts/<script> once in TEST_IMAGE, shows + saves logs, returns pod's exit status.
run_pod() {
  local ns="$1" pod="$2" script="$3" env="${4:-}" vm="${5:-}" vol="${6:-}"
  kubectl -n "$ns" delete pod "$pod" --ignore-not-found --wait=true >/dev/null
  apply "pod-$ns-$pod" >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: $pod, namespace: $ns, labels: {app.kubernetes.io/part-of: vks-test}}
spec:
  restartPolicy: Never
$POD_SEC
  containers:
    - name: t
      image: $TEST_IMAGE
      command: ["/bin/bash", "/scripts/$script"]
$CTR_SEC
      env:
$AWS_ENV
$env
      volumeMounts:
        - {name: scripts, mountPath: /scripts}
$vm
  volumes:
    - name: scripts
      configMap: {name: vks-scripts}
$vol
EOF
  local rc=0
  wait_pod_done "$ns" "$pod" || rc=1
  ev "log-$ns-$pod" kubectl -n "$ns" logs "$pod" || true
  return $rc
}

# tools <script> [args via env]: run a script as the RING root account from the vks-tools namespace.
root_env() {
  cat <<EOF
      - {name: S3_ENDPOINT, value: "$S3_ENDPOINT"}
      - {name: AWS_DEFAULT_REGION, value: "$S3_REGION"}
      - name: AWS_ACCESS_KEY_ID
        valueFrom: {secretKeyRef: {name: ring-root, key: AWS_ACCESS_KEY_ID}}
      - name: AWS_SECRET_ACCESS_KEY
        valueFrom: {secretKeyRef: {name: ring-root, key: AWS_SECRET_ACCESS_KEY}}
EOF
}
tools() {  # tools <pod-suffix> <script> [ARG1] [ARG2] [ARG3]
  local name="$1" script="$2"
  local extra="      - {name: ARG1, value: \"${3:-}\"}
      - {name: ARG2, value: \"${4:-}\"}
      - {name: ARG3, value: \"${5:-}\"}"
  run_pod "$TOOLS_NS" "root-$name" "$script" "$(root_env)
$extra"
}

ensure_tools_ns() {
  ns_create "$TOOLS_NS"
  secret_root "$TOOLS_NS" ring-root aws
  scripts_cm "$TOOLS_NS"
}

ensure_helm() {
  command -v helm >/dev/null && return 0
  say "helm not found — installing $HELM_VERSION to ~/.local/bin"
  mkdir -p "$HOME/.local/bin"
  curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" \
    | tar -xz -C "$HOME/.local/bin" --strip-components=1 linux-amd64/helm \
    || die "could not download helm from get.helm.sh"
}

# ================================================================= phases
phase_preflight() {
  check_token
  ev context      kubectl config current-context
  ev version      kubectl version
  ev nodes        kubectl get nodes -o wide
  ev storageclass kubectl get storageclass
  ev namespaces   kubectl get ns --show-labels
  ev can-i        kubectl auth can-i '*' '*' --all-namespaces

  local minor
  minor="$(kubectl version -o json 2>/dev/null | sed -n 's/.*"minor": *"\([0-9]*\).*/\1/p' | tail -1)"
  if [[ -n $minor && $minor -ge 30 ]]; then result PF-1 PASS "Kubernetes 1.$minor (CSI 2.x needs ≥ 1.30)"
  else result PF-1 FAIL "Kubernetes minor '$minor' — CSI 2.x needs ≥ 1.30"; fi

  if kubectl auth can-i '*' '*' --all-namespaces >/dev/null 2>&1; then result PF-2 PASS "cluster-admin rights"
  else result PF-2 FAIL "not cluster-admin — CRDs and the CSI DaemonSet cannot be installed"; fi

  local u ok=1
  for u in https://ghcr.io/v2/ https://gcr.io/v2/ https://github.com https://public.ecr.aws "$S3_ENDPOINT"; do
    if curl -s -m 10 -o /dev/null "$u"; then echo "jumphost -> $u : reachable"; else echo "jumphost -> $u : UNREACHABLE"; fi
  done | tee "$RES/evidence/preflight--jumphost-egress.txt"
  grep -q UNREACHABLE "$RES/evidence/preflight--jumphost-egress.txt" && ok=0
  (( ok )) && result PF-3 PASS "jumphost reaches ghcr.io, gcr.io, github.com, public.ecr.aws, S3" \
           || result PF-3 FAIL "jumphost egress blocked (see evidence/preflight--jumphost-egress.txt)"

  command -v git >/dev/null && result PF-4 PASS "git present (needed by kubectl -k github.com/...)" \
                            || result PF-4 FAIL "git missing on the jumphost (sudo apt-get install -y git)"
  ensure_helm && ev helm-version helm version && result PF-5 PASS "helm $(helm version --short 2>/dev/null)"

  ensure_tools_ns
  if tools preflight preflight.sh "$P-preflight"; then
    result PF-6 PASS "from a cluster pod: registries reachable, S3 + IAM answer with the account keys"
  else
    result PF-6 FAIL "cluster pod check failed — see evidence/preflight--log-$TOOLS_NS-root-preflight.txt (ImagePullBackOff = no egress to public.ecr.aws)"
  fi

  shot 01-vks-cluster.png "Jumphost browser window showing the output above: kubectl version + kubectl get nodes -o wide (the VKS cluster for the RA 'cluster configuration' section)."
  if grep -q $'\tFAIL\t' <(grep '^PF-' "$RES/summary.tsv"); then
    die "preflight has FAIL lines — fix them (or tell Claude) before installing. Re-run: ./run.sh --only preflight"
  fi
}

phase_cosi_install() {
  check_token; ensure_helm
  say "COSI controller + CRDs ($COSI_CONTROLLER_REF)"
  ev controller kubectl apply -k "github.com/kubernetes-sigs/container-object-storage-interface//?ref=$COSI_CONTROLLER_REF" \
    || die "COSI controller install failed"
  # The driver pod sets no securityContext, so its namespace cannot be 'restricted'.
  ns_create "$COSI_NS" privileged
  kubectl -n "$COSI_NS" wait --for=condition=Available deploy --all --timeout="$WAIT" || warn "controller not Available yet"

  say "Scality COSI driver $COSI_CHART_VERSION"
  ev helm-install helm upgrade --install scality-cosi-driver "$COSI_CHART" --version "$COSI_CHART_VERSION" \
    --namespace "$COSI_NS" --wait --timeout "$WAIT" || die "helm install of the COSI driver failed (ImagePullBackOff? check gcr.io egress)"
  secret_root "$COSI_NS" s3-secret-for-cosi cosi
  kubectl -n "$COSI_NS" wait pod --all --for=condition=Ready --timeout="$WAIT"

  ev crds   bash -c "kubectl get crd | grep objectstorage.k8s.io"
  ev pods   kubectl -n "$COSI_NS" get pods -o wide
  ev images kubectl -n "$COSI_NS" get pods -o 'custom-columns=POD:.metadata.name,IMAGES:.spec.containers[*].image'
  ev helm-list helm list -n "$COSI_NS"
  if kubectl -n "$COSI_NS" get pods --no-headers | grep -v Running | grep -q .; then
    result CI-1 FAIL "COSI pods not all Running"
  else result CI-1 PASS "COSI controller + Scality COSI driver $COSI_CHART_VERSION running"; fi
  shot 02-cosi-installed.png "Jumphost window: 'kubectl get pods -n $COSI_NS' and the CRD list above (COSI controller + Scality driver running on VKS)."
}

cosi_classes() {
  apply cosi-classes <<EOF
kind: BucketClass
apiVersion: objectstorage.k8s.io/v1alpha1
metadata: {name: $P-del}
driverName: cosi.scality.com
deletionPolicy: Delete
parameters: {objectStorageSecretName: s3-secret-for-cosi, objectStorageSecretNamespace: $COSI_NS}
---
kind: BucketClass
apiVersion: objectstorage.k8s.io/v1alpha1
metadata: {name: $P-ret}
driverName: cosi.scality.com
deletionPolicy: Retain
parameters: {objectStorageSecretName: s3-secret-for-cosi, objectStorageSecretNamespace: $COSI_NS}
---
kind: BucketAccessClass
apiVersion: objectstorage.k8s.io/v1alpha1
metadata: {name: $P-bac}
driverName: cosi.scality.com
authenticationType: KEY
parameters: {objectStorageSecretName: s3-secret-for-cosi, objectStorageSecretNamespace: $COSI_NS}
EOF
}

cosi_claim() {  # cosi_claim <ns> <claim> <class>
  apply "claim-$1-$2" <<EOF
kind: BucketClaim
apiVersion: objectstorage.k8s.io/v1alpha1
metadata: {name: $2, namespace: $1}
spec: {bucketClassName: $3, protocols: [s3]}
EOF
  kubectl -n "$1" wait "bucketclaim/$2" --for=jsonpath='{.status.bucketReady}'=true --timeout="$WAIT"
}
cosi_access() {  # cosi_access <ns> <access> <claim> <secret>
  apply "access-$1-$2" <<EOF
kind: BucketAccess
apiVersion: objectstorage.k8s.io/v1alpha1
metadata: {name: $2, namespace: $1}
spec: {bucketClaimName: $3, bucketAccessClassName: $P-bac, credentialsSecretName: $4, protocol: s3}
EOF
  kubectl -n "$1" wait "bucketaccess/$2" --for=jsonpath='{.status.accessGranted}'=true --timeout="$WAIT"
}
s3_bucket_of() {  # s3_bucket_of <ns> <claim> -> real S3 bucket name
  local b; b="$(kubectl -n "$1" get bucketclaim "$2" -o jsonpath='{.status.bucketName}')"
  local id; id="$(kubectl get bucket "$b" -o jsonpath='{.status.bucketID}' 2>/dev/null)"
  echo "${id:-$b}"
}
cosi_app() {  # cosi_app <ns> <pod> <secret> <script> [ARG1]
  run_pod "$1" "$2" "$4" "      - {name: ARG1, value: \"${5:-}\"}" \
    "        - {name: cosi, mountPath: /cosi, readOnly: true}" \
    "    - name: cosi
      secret: {secretName: $3}"
}

phase_cosi_test() {
  check_token; ensure_tools_ns
  ns_create "$NS_COSI_A"; ns_create "$NS_COSI_B"
  scripts_cm "$NS_COSI_A"; scripts_cm "$NS_COSI_B"
  cosi_classes
  ev classes bash -c "kubectl get bucketclass,bucketaccessclass"

  # CT-1 greenfield bucket
  if cosi_claim "$NS_COSI_A" claim-a "$P-del"; then
    BUCKET_A="$(s3_bucket_of "$NS_COSI_A" claim-a)"
    if tools head-a s3-head.sh "$BUCKET_A"; then result CT-1 PASS "BucketClaim → bucket $BUCKET_A exists on RING"
    else result CT-1 FAIL "BucketClaim ready but bucket $BUCKET_A not found on RING"; fi
  else result CT-1 FAIL "BucketClaim claim-a not ready"; return 1; fi

  # CT-2 access: IAM user + secret
  if cosi_access "$NS_COSI_A" access-a claim-a creds-a; then
    ev iam-users bash -c "kubectl get bucketaccess -A; kubectl -n $NS_COSI_A get secret creds-a"
    tools iam-list iam-list.sh >/dev/null || true
    result CT-2 PASS "BucketAccess granted: IAM user created, secret creds-a (BucketInfo) in $NS_COSI_A"
  else result CT-2 FAIL "BucketAccess access-a not granted"; return 1; fi

  # CT-3 app read/write with the COSI-issued credentials
  if cosi_app "$NS_COSI_A" app-a creds-a cosi-app.sh; then result CT-3 PASS "app pod put/list/get/checksum OK with COSI credentials"
  else result CT-3 FAIL "app pod failed with COSI credentials"; fi
  ev resources bash -c "kubectl get bucketclaim,bucketaccess -A; kubectl get bucket"
  shot 03-cosi-bucket-cyberduck.png "On your laptop (Cyberduck/console, account root keys): bucket '$BUCKET_A' with the object(s) under 'cosi-test/' written by the VKS pod."
  shot 04-cosi-k8s-objects.png "Jumphost window: the 'kubectl get bucketclaim,bucketaccess -A' output above."

  # CT-4 second namespace, isolation
  if cosi_claim "$NS_COSI_B" claim-b "$P-ret" && cosi_access "$NS_COSI_B" access-b claim-b creds-b; then
    BUCKET_B="$(s3_bucket_of "$NS_COSI_B" claim-b)"
    if cosi_app "$NS_COSI_B" app-b creds-b cosi-app.sh && cosi_app "$NS_COSI_B" iso-b creds-b cosi-isolation.sh "$BUCKET_A"; then
      result CT-4 PASS "namespace B has its own bucket $BUCKET_B; its credentials are denied on $BUCKET_A"
    else result CT-4 FAIL "isolation check failed (see logs app-b / iso-b)"; fi
  else result CT-4 FAIL "claim-b/access-b not ready"; fi
  shot 05-two-buckets-cyberduck.png "On your laptop: bucket list showing both '$BUCKET_A' (namespace $NS_COSI_A) and '$BUCKET_B' (namespace $NS_COSI_B)."

  # CT-5 revoke: keep a copy of creds-a, delete the BucketAccess, old keys must stop working
  kubectl -n "$NS_COSI_A" get secret creds-a -o jsonpath='{.data.BucketInfo}' | base64 -d > "$RES/.creds-a.json"
  kubectl -n "$NS_COSI_A" create secret generic creds-a-saved --from-file=BucketInfo="$RES/.creds-a.json" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  rm -f "$RES/.creds-a.json"
  kubectl -n "$NS_COSI_A" delete bucketaccess access-a --wait=true
  sleep 15   # let IAM key deletion propagate
  if cosi_app "$NS_COSI_A" revoked-a creds-a-saved cosi-expect-denied.sh; then
    result CT-5 PASS "after deleting BucketAccess the old keys are rejected"
  else result CT-5 FAIL "old keys still work after BucketAccess deletion"; fi
  kubectl -n "$NS_COSI_A" delete secret creds-a-saved --ignore-not-found >/dev/null

  # CT-6 deletionPolicy Delete: empty the bucket, delete claim, bucket must disappear
  tools empty-a s3-empty.sh "$BUCKET_A" >/dev/null || true
  kubectl -n "$NS_COSI_A" delete bucketclaim claim-a --wait=true --timeout="$WAIT"
  sleep 10
  if tools gone-a s3-expect-gone.sh "$BUCKET_A"; then result CT-6 PASS "deletionPolicy Delete: bucket $BUCKET_A removed with its claim"
  else result CT-6 FAIL "bucket $BUCKET_A still exists after deleting a Delete-policy claim"; fi

  # CT-7 deletionPolicy Retain: claim-r created and deleted, bucket must remain
  if cosi_claim "$NS_COSI_B" claim-r "$P-ret"; then
    local br; br="$(s3_bucket_of "$NS_COSI_B" claim-r)"
    kubectl -n "$NS_COSI_B" delete bucketclaim claim-r --wait=true --timeout="$WAIT"
    sleep 10
    if tools head-r s3-head.sh "$br"; then result CT-7 PASS "deletionPolicy Retain: bucket $br kept after its claim was deleted"
    else result CT-7 FAIL "Retain bucket $br disappeared"; fi
    tools rm-r s3-empty.sh "$br" delete >/dev/null || true
  else result CT-7 FAIL "claim-r not ready"; fi
  ev final bash -c "kubectl get bucketclaim,bucketaccess -A; kubectl get bucket"
}

phase_csi_install() {
  check_token; ensure_helm
  ns_create "$CSI_NS" privileged       # node DaemonSet is privileged (FUSE mounts)
  secret_root "$CSI_NS" s3-secret csi
  ev helm-install helm upgrade --install scality-mountpoint-s3-csi-driver "$CSI_CHART" --version "$CSI_CHART_VERSION" \
    --namespace "$CSI_NS" --set s3.endpointUrl="$S3_ENDPOINT" --set s3.region="$S3_REGION" \
    --set node.s3EndpointUrl="$S3_ENDPOINT" --set node.s3Region="$S3_REGION" \
    --set s3CredentialSecret.name=s3-secret --wait --timeout "$WAIT" \
    || die "helm install of the CSI driver failed (ImagePullBackOff? privileged pods refused?)"
  kubectl -n "$CSI_NS" rollout status ds --timeout="$WAIT"
  kubectl -n "$CSI_NS" wait pod --all --for=condition=Ready --timeout="$WAIT"
  ev pods      kubectl -n "$CSI_NS" get pods -o wide
  ev images    kubectl -n "$CSI_NS" get pods -o 'custom-columns=POD:.metadata.name,IMAGES:.spec.containers[*].image'
  ev csidriver kubectl get csidriver s3.csi.scality.com
  ev helm-list helm list -n "$CSI_NS"
  if kubectl -n "$CSI_NS" get pods --no-headers | grep -v Running | grep -q .; then
    result SI-1 FAIL "CSI pods not all Running"
  else result SI-1 PASS "Scality CSI driver $CSI_CHART_VERSION running (node DaemonSet on every node + controller)"; fi
  shot 06-csi-installed.png "Jumphost window: 'kubectl get pods -n $CSI_NS -o wide' and 'kubectl get csidriver' above (one node pod per VKS worker)."
}

csi_pod() {  # csi_pod <pod> <pvc> <script> [ARG1] — runs a test script with the PVC at /data
  run_pod "$NS_CSI" "$1" "$3" "      - {name: ARG1, value: \"${4:-}\"}" \
    "        - {name: data, mountPath: /data}" \
    "    - name: data
      persistentVolumeClaim: {claimName: $2}"
}
MOUNT_OPTS="    - allow-delete
    - allow-overwrite
    - allow-other
    - uid=1000
    - gid=1000"

phase_csi_test() {
  check_token; ensure_tools_ns
  ns_create "$NS_CSI"; scripts_cm "$NS_CSI"
  local bs="$P-csi-static"

  # CS-1 static provisioning on a pre-created bucket
  tools mk-static s3-mkbucket.sh "$bs" || { result CS-1 FAIL "could not create bucket $bs"; return 1; }
  apply static-pv <<EOF
apiVersion: v1
kind: PersistentVolume
metadata: {name: $P-static-pv}
spec:
  capacity: {storage: 10Gi}
  accessModes: [ReadWriteMany]
  storageClassName: ""
  claimRef: {namespace: $NS_CSI, name: static-pvc}
  mountOptions:
$MOUNT_OPTS
  csi:
    driver: s3.csi.scality.com
    volumeHandle: $P-static-volume
    volumeAttributes: {bucketName: $bs}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: static-pvc, namespace: $NS_CSI}
spec:
  accessModes: [ReadWriteMany]
  storageClassName: ""
  resources: {requests: {storage: 10Gi}}
  volumeName: $P-static-pv
EOF
  kubectl -n "$NS_CSI" wait pvc/static-pvc --for=jsonpath='{.status.phase}'=Bound --timeout="$WAIT"
  if csi_pod writer static-pvc csi-write.sh; then result CS-1 PASS "static PV/PVC on bucket $bs: pod wrote files through the CSI mount"
  else result CS-1 FAIL "write through static CSI volume failed"; fi

  # CS-2 a second pod reads the same volume (RWX)
  if csi_pod reader static-pvc csi-verify.sh; then result CS-2 PASS "second pod read the same files, checksums match"
  else result CS-2 FAIL "second pod could not read/verify the files"; fi

  # CS-3 the files are plain S3 objects
  if tools ls-static s3-verify-csi.sh "$bs"; then result CS-3 PASS "files written via CSI are S3 objects in $bs, checksum matches over S3"
  else result CS-3 FAIL "objects not visible / checksum mismatch over S3"; fi

  # CS-4 persistence across pod restart (new pod, same PVC)
  kubectl -n "$NS_CSI" delete pod writer reader --ignore-not-found --wait=true >/dev/null
  if csi_pod after-restart static-pvc csi-verify.sh; then result CS-4 PASS "data still there for a new pod after the first pods were deleted"
  else result CS-4 FAIL "data missing after pod restart"; fi
  ev static-objects bash -c "kubectl get pv $P-static-pv; kubectl -n $NS_CSI get pvc,pods"
  shot 07-csi-static-cyberduck.png "On your laptop: bucket '$bs' showing the 'csi-test/' files written by the VKS pods."
  shot 08-csi-static-k8s.png "Jumphost window: the 'kubectl get pv / pvc,pods' output above."

  # CS-5 dynamic provisioning via StorageClass
  apply storageclass <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata: {name: $P-s3}
provisioner: s3.csi.scality.com
reclaimPolicy: Delete
volumeBindingMode: Immediate
parameters:
  csi.storage.k8s.io/provisioner-secret-name: s3-secret
  csi.storage.k8s.io/provisioner-secret-namespace: $CSI_NS
  csi.storage.k8s.io/node-publish-secret-name: s3-secret
  csi.storage.k8s.io/node-publish-secret-namespace: $CSI_NS
mountOptions:
$MOUNT_OPTS
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: dynamic-pvc, namespace: $NS_CSI}
spec:
  accessModes: [ReadWriteMany]
  storageClassName: $P-s3
  resources: {requests: {storage: 10Gi}}
EOF
  local bd=""
  if kubectl -n "$NS_CSI" wait pvc/dynamic-pvc --for=jsonpath='{.status.phase}'=Bound --timeout="$WAIT"; then
    local pv; pv="$(kubectl -n "$NS_CSI" get pvc dynamic-pvc -o jsonpath='{.spec.volumeName}')"
    bd="$(kubectl get pv "$pv" -o jsonpath='{.spec.csi.volumeAttributes.bucketName}')"
    [[ -z $bd ]] && bd="$(kubectl get pv "$pv" -o jsonpath='{.spec.csi.volumeHandle}')"
    if csi_pod dyn-writer dynamic-pvc csi-write.sh && csi_pod dyn-reader dynamic-pvc csi-verify.sh \
       && tools ls-dyn s3-verify-csi.sh "$bd"; then
      result CS-5 PASS "StorageClass $P-s3 provisioned bucket $bd; write/read via CSI and S3 OK"
    else result CS-5 FAIL "dynamic volume write/read failed"; fi
  else result CS-5 FAIL "dynamic PVC not Bound"; fi
  ev dynamic-objects bash -c "kubectl get sc $P-s3; kubectl get pv; kubectl -n $NS_CSI get pvc"
  shot 09-csi-dynamic-cyberduck.png "On your laptop: the bucket '$bd' created by the StorageClass, with its 'csi-test/' files."
  shot 10-csi-dynamic-k8s.png "Jumphost window: the 'kubectl get sc / pv / pvc' output above."

  # CS-6 reclaimPolicy Delete: empty volume, delete PVC, bucket must go
  if [[ -n $bd ]]; then
    kubectl -n "$NS_CSI" delete pod dyn-writer dyn-reader --ignore-not-found --wait=true >/dev/null
    tools empty-dyn s3-empty.sh "$bd" >/dev/null || true
    kubectl -n "$NS_CSI" delete pvc dynamic-pvc --wait=true --timeout="$WAIT"
    sleep 15
    if tools gone-dyn s3-expect-gone.sh "$bd"; then result CS-6 PASS "reclaimPolicy Delete: bucket $bd removed with its PVC"
    else result CS-6 FAIL "bucket $bd still exists after PVC deletion"; fi
  else result CS-6 SKIP "no dynamic bucket"; fi
}

phase_collect() {
  check_token
  ev all-test-objects bash -c "kubectl get bucketclass,bucketaccessclass,bucket; kubectl get bucketclaim,bucketaccess,pvc,pods -A | grep -E '^NAMESPACE|^vks-'; kubectl get pv,sc,csidriver"
  ev helm-values bash -c "helm get values scality-cosi-driver -n $COSI_NS; helm get values scality-mountpoint-s3-csi-driver -n $CSI_NS 2>/dev/null || true"
  {
    echo "# VKS × Scality drivers — run $RUN_ID ($(date -u +%FT%TZ))"
    echo "endpoint: $S3_ENDPOINT   region: $S3_REGION   COSI $COSI_CHART_VERSION (controller $COSI_CONTROLLER_REF)   CSI $CSI_CHART_VERSION"
    echo; column -t -s $'\t' "$RES/summary.tsv"
    echo; echo "Screenshots requested:"; column -t -s $'\t' "$RES/screenshots.tsv"
  } | tee "$RES/SUMMARY.txt"
  # make sure no key ever ended up in the results
  if grep -rqF -e "$AWS_SECRET_ACCESS_KEY" -e "$AWS_ACCESS_KEY_ID" "$RES"; then
    die "an access key was found in $RES — not uploading. Tell Claude which file."
  fi
  local tgz="$HOME/vks-results-$RUN_ID.tgz"
  tar -czf "$tgz" -C "$(dirname "$RES")" "$RUN_ID"
  ensure_tools_ns
  tools mk-results s3-mkbucket.sh "$RESULTS_BUCKET" >/dev/null || true
  # stream the tarball into a long-lived tools pod and upload it as the root account
  kubectl -n "$TOOLS_NS" delete pod uploader --ignore-not-found --wait=true >/dev/null
  kubectl -n "$TOOLS_NS" run uploader --image="$TEST_IMAGE" --restart=Never --command \
    --overrides="$(uploader_overrides)" -- sleep 600 >/dev/null
  kubectl -n "$TOOLS_NS" wait pod/uploader --for=condition=Ready --timeout="$WAIT" >/dev/null
  if kubectl -n "$TOOLS_NS" exec -i uploader -- aws --endpoint-url "$S3_ENDPOINT" \
       s3 cp - "s3://$RESULTS_BUCKET/vks-results-$RUN_ID.tgz" < "$tgz"; then
    result CO-1 PASS "results uploaded to s3://$RESULTS_BUCKET/vks-results-$RUN_ID.tgz"
  else result CO-1 FAIL "upload failed — results are in $tgz"; fi
  kubectl -n "$TOOLS_NS" delete pod uploader --ignore-not-found --wait=false >/dev/null
  say "Done. Tell Claude: run $RUN_ID, results in s3://$RESULTS_BUCKET/vks-results-$RUN_ID.tgz"
}
uploader_overrides() {
  cat <<EOF
{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}},
 "containers":[{"name":"uploader","image":"$TEST_IMAGE","command":["sleep","600"],
  "securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}},
  "env":[{"name":"HOME","value":"/tmp"},{"name":"AWS_EC2_METADATA_DISABLED","value":"true"},
   {"name":"AWS_CONFIG_FILE","value":"/scripts/aws-config"},{"name":"AWS_DEFAULT_REGION","value":"$S3_REGION"},
   {"name":"AWS_ACCESS_KEY_ID","valueFrom":{"secretKeyRef":{"name":"ring-root","key":"AWS_ACCESS_KEY_ID"}}},
   {"name":"AWS_SECRET_ACCESS_KEY","valueFrom":{"secretKeyRef":{"name":"ring-root","key":"AWS_SECRET_ACCESS_KEY"}}}],
  "volumeMounts":[{"name":"scripts","mountPath":"/scripts"}]}],
 "volumes":[{"name":"scripts","configMap":{"name":"vks-scripts"}}]}}
EOF
}

phase_cleanup() {
  CUR_PHASE=cleanup; check_token
  say "Removing test workloads, classes, drivers and test buckets for run $RUN_ID (results bucket $RESULTS_BUCKET is kept)"
  read -r -p "Type 'yes' to continue: " a; [[ $a == yes ]] || die "aborted"
  kubectl delete ns "$NS_COSI_A" "$NS_COSI_B" "$NS_CSI" --ignore-not-found --wait=true --timeout="$WAIT" \
    || warn "namespaces still terminating (finalizers) - check 'kubectl get bucketaccess,bucketclaim -A'"
  kubectl delete pv "$P-static-pv" --ignore-not-found
  kubectl delete sc "$P-s3" --ignore-not-found
  kubectl delete bucketclass "$P-del" "$P-ret" --ignore-not-found 2>/dev/null
  kubectl delete bucketaccessclass "$P-bac" --ignore-not-found 2>/dev/null
  ensure_tools_ns
  tools purge s3-purge-prefix.sh "$P-" "$RESULTS_BUCKET" || warn "bucket purge reported errors"
  helm uninstall scality-mountpoint-s3-csi-driver -n "$CSI_NS" 2>/dev/null
  helm uninstall scality-cosi-driver -n "$COSI_NS" 2>/dev/null
  kubectl delete -k "github.com/kubernetes-sigs/container-object-storage-interface//?ref=$COSI_CONTROLLER_REF" --ignore-not-found
  kubectl delete ns "$CSI_NS" "$TOOLS_NS" --ignore-not-found --timeout="$WAIT"
  say "Cleanup done. Keys file $CONFIG_FILE left in place — delete it when the lab is finished: rm $CONFIG_FILE"
}

# ================================================================= main
FROM=""; ONLY=""; YES=0; CLEANUP=0; RESET_CONFIG=0; WITH_CSI=0
while (($#)); do
  case $1 in
    --from) FROM="$2"; shift ;;
    --only) ONLY="$2"; shift ;;
    --yes|-y) YES=1 ;;
    --cleanup) CLEANUP=1 ;;
    --reset-config) RESET_CONFIG=1 ;;
    --with-csi) WITH_CSI=1 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) die "unknown argument $1 (see --help)" ;;
  esac; shift
done
command -v kubectl >/dev/null || die "kubectl not found"
load_config
say "Run $RUN_ID — results in $RES"
if (( CLEANUP )); then phase_cleanup; exit 0; fi
if (( WITH_CSI )) || [[ " ${CSI_PHASES[*]} " == *" $FROM "* || " ${CSI_PHASES[*]} " == *" $ONLY "* ]]; then
  PHASES=(preflight cosi-install cosi-test "${CSI_PHASES[@]}" collect)
else
  say "CSI phases excluded (scality/mountpoint-s3-csi-driver#387: RING 9.5.3 RestoreStatus); use --with-csi to run them"
fi

started=0; [[ -z $FROM && -z $ONLY ]] && started=1
for ph in "${PHASES[@]}"; do
  [[ -n $ONLY && $ph != "$ONLY" ]] && continue
  [[ $ph == "$FROM" ]] && started=1
  [[ -z $ONLY ]] && (( !started )) && continue
  CUR_PHASE="$ph"
  say "──────── phase: $ph ────────"
  "phase_${ph//-/_}"
done
echo; column -t -s $'\t' "$RES/summary.tsv" 2>/dev/null
