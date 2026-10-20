set -uo pipefail
d=/data/csi-test
ls -l $d && cat $d/hello.txt
(cd $d && sha256sum -c SHA256SUMS) && echo "OK   checksums verified by ${HOSTNAME:-pod}" || { echo "FAIL checksum"; exit 1; }
