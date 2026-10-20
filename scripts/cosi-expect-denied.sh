# Uses credentials of a deleted BucketAccess; every call must fail.
source /scripts/common.sh
cosi_env
if s3 ls "s3://$BUCKET/" >/dev/null 2>&1; then bad "revoked keys still list $BUCKET"; else ok "revoked keys rejected on LIST"; fi
if echo x | s3 cp - "s3://$BUCKET/after-revoke.txt" >/dev/null 2>&1; then bad "revoked keys can still write"; else ok "revoked keys rejected on PUT"; fi
