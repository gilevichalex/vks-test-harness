source /scripts/common.sh
if s3a head-bucket --bucket "$ARG1" 2>/dev/null; then bad "bucket $ARG1 still exists"; else ok "bucket $ARG1 no longer exists"; fi
