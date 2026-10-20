# Plays the application: uses ONLY the COSI-issued credentials to write/read its bucket.
source /scripts/common.sh
cosi_env
f=/tmp/payload.bin; head -c 1048576 /dev/urandom > $f; sum="$(sha256sum $f | cut -d' ' -f1)"
key="cosi-test/${HOSTNAME:-pod}-$(date -u +%Y%m%dT%H%M%SZ).bin"
s3 cp $f "s3://$BUCKET/$key" --only-show-errors && ok "PUT $key (1 MiB)" || bad "PUT"
echo "hello from VKS pod ${HOSTNAME:-pod}" | s3 cp - "s3://$BUCKET/cosi-test/hello.txt" --only-show-errors && ok "PUT cosi-test/hello.txt" || bad "PUT hello"
s3 ls "s3://$BUCKET/cosi-test/" && ok "LIST" || bad "LIST"
s3 cp "s3://$BUCKET/$key" /tmp/back.bin --only-show-errors && ok "GET $key" || bad "GET"
[[ "$(sha256sum /tmp/back.bin | cut -d' ' -f1)" == "$sum" ]] && ok "checksum match $sum" || bad "checksum mismatch"
