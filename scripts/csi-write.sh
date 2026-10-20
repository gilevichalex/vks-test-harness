# Writes through the CSI mount at /data (no S3 credentials in this pod).
set -uo pipefail
d=/data/csi-test
mkdir -p $d || { echo "FAIL mkdir"; exit 1; }
rm -f $d/* 2>/dev/null
echo "hello from VKS pod ${HOSTNAME:-pod} at $(date -u +%FT%TZ)" > $d/hello.txt || { echo "FAIL write hello.txt"; exit 1; }
head -c 5242880 /dev/urandom > $d/random-5MiB.bin || { echo "FAIL write random file"; exit 1; }
(cd $d && sha256sum hello.txt random-5MiB.bin > /tmp/SHA256SUMS) && cp /tmp/SHA256SUMS $d/SHA256SUMS || { echo "FAIL checksums"; exit 1; }
ls -l $d; df -h /data | tail -1; mount | grep ' /data ' || true
echo "OK   wrote $d"
