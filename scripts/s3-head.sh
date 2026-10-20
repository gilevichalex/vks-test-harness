source /scripts/common.sh
s3a head-bucket --bucket "$ARG1" && ok "bucket $ARG1 exists" || bad "bucket $ARG1 not found"
s3 ls "s3://$ARG1/" --recursive | head -20
