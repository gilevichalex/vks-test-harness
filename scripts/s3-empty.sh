# ARG1 bucket, ARG2=delete to also remove the bucket
source /scripts/common.sh
s3 rm "s3://$ARG1" --recursive --only-show-errors; ok "emptied $ARG1"
[[ ${ARG2:-} == delete ]] && { s3a delete-bucket --bucket "$ARG1" && ok "deleted bucket $ARG1"; }
exit 0
