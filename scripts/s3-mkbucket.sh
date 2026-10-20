source /scripts/common.sh
s3a head-bucket --bucket "$ARG1" 2>/dev/null && { ok "bucket $ARG1 already exists"; exit 0; }
s3a create-bucket --bucket "$ARG1" >/dev/null && ok "created bucket $ARG1" || bad "create-bucket $ARG1"
