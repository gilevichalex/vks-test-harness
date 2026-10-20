# Sourced by every in-pod script. Never print key material.
set -uo pipefail
s3()  { aws --endpoint-url "$S3_ENDPOINT" s3 "$@"; }
s3a() { aws --endpoint-url "$S3_ENDPOINT" s3api "$@"; }
iam() { aws --endpoint-url "$S3_ENDPOINT" iam "$@"; }
ok()   { echo "OK   $*"; }
bad()  { echo "FAIL $*"; exit 1; }
# cosi_env: load the COSI BucketInfo secret (KEP-1979 format) mounted at /cosi/BucketInfo
cosi_env() {
  local j; j="$(cat /cosi/BucketInfo)" || bad "no /cosi/BucketInfo"
  f() { printf '%s' "$j" | grep -o "\"$1\": *\"[^\"]*\"" | head -1 | sed 's/.*: *"\(.*\)"/\1/'; }
  BUCKET="$(f bucketName)"; S3_ENDPOINT="$(f endpoint)"
  export AWS_ACCESS_KEY_ID="$(f accessKeyID)" AWS_SECRET_ACCESS_KEY="$(f accessSecretKey)"
  export AWS_DEFAULT_REGION="$(f region)"; [[ -n $AWS_DEFAULT_REGION ]] || export AWS_DEFAULT_REGION=us-east-1
  [[ -n $BUCKET && -n $S3_ENDPOINT && -n $AWS_ACCESS_KEY_ID ]] || bad "BucketInfo incomplete"
  echo "BucketInfo: bucket=$BUCKET endpoint=$S3_ENDPOINT region=$AWS_DEFAULT_REGION authenticationType=$(f authenticationType)"
}
