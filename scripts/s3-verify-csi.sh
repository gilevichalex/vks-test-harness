# ARG1 bucket written via CSI: objects must be plain S3 objects with matching checksums.
source /scripts/common.sh
s3 ls "s3://$ARG1/csi-test/" || bad "no csi-test/ objects in $ARG1"
s3 cp "s3://$ARG1/csi-test/SHA256SUMS" /tmp/S --only-show-errors && s3 cp "s3://$ARG1/csi-test/random-5MiB.bin" /tmp/random-5MiB.bin --only-show-errors || bad "GET"
want="$(grep random-5MiB.bin /tmp/S | cut -d' ' -f1)"; got="$(sha256sum /tmp/random-5MiB.bin | cut -d' ' -f1)"
[[ $want == "$got" ]] && ok "S3 object checksum matches the file written via CSI" || bad "checksum mismatch"
