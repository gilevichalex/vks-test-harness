# Root account checks from inside the cluster. ARG1 = throwaway bucket name.
source /scripts/common.sh
rc=0
for u in https://ghcr.io/v2/ https://gcr.io/v2/ https://github.com "$S3_ENDPOINT"; do
  code="$(curl -s -m 10 -o /dev/null -w '%{http_code}' "$u")"
  if [[ $code != 000 ]]; then ok "pod -> $u (HTTP $code)"; else echo "FAIL pod -> $u unreachable"; rc=1; fi
done
n="$(s3a list-buckets --query 'length(Buckets)' --output text)" && ok "S3 list-buckets with account keys ($n buckets)" || { echo "FAIL S3 list-buckets"; rc=1; }
s3a create-bucket --bucket "$ARG1" >/dev/null && s3a delete-bucket --bucket "$ARG1" && ok "S3 create+delete bucket $ARG1" || { echo "FAIL create/delete bucket"; rc=1; }
u="$(iam list-users --query 'length(Users)' --output text)" && ok "IAM list-users on the same endpoint ($u users)" || { echo "FAIL IAM list-users (COSI BucketAccess needs IAM)"; rc=1; }
exit $rc
