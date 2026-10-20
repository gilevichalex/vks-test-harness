# Verbatim copy of the snippet in the public reference architecture (do not edit here; edit the doc, then re-copy).
kubectl -n app-team-a apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: app-a
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    seccompProfile: {type: RuntimeDefault}
  containers:
    - name: app
      image: public.ecr.aws/aws-cli/aws-cli:2.17.0
      env:
        - {name: HOME, value: /tmp}
      command: ["/bin/bash", "-c"]
      args:
        - |
          set -euo pipefail
          # Read the connection details COSI wrote into the Secret
          INFO=$(cat /cosi/BucketInfo)
          get() { echo "$INFO" | grep -o "\"$1\": *\"[^\"]*\"" | head -1 | sed 's/.*: *"\(.*\)"/\1/'; }
          export AWS_ACCESS_KEY_ID=$(get accessKeyID) AWS_SECRET_ACCESS_KEY=$(get accessSecretKey)
          REGION=$(get region); export AWS_DEFAULT_REGION=${REGION:-us-east-1}
          BUCKET=$(get bucketName); ENDPOINT=$(get endpoint)
          aws configure set default.s3.addressing_style path
          # Write, list and read back an object
          echo "hello from VKS" > /tmp/hello.txt
          aws --endpoint-url "$ENDPOINT" s3 cp /tmp/hello.txt "s3://$BUCKET/cosi-test/hello.txt"
          aws --endpoint-url "$ENDPOINT" s3 ls "s3://$BUCKET/cosi-test/"
          aws --endpoint-url "$ENDPOINT" s3 cp "s3://$BUCKET/cosi-test/hello.txt" -
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: {drop: [ALL]}
      volumeMounts:
        - {name: cosi, mountPath: /cosi, readOnly: true}
  volumes:
    - name: cosi
      secret: {secretName: app-bucket-creds}
EOF

kubectl -n app-team-a wait pod/app-a --for=jsonpath='{.status.phase}'=Succeeded --timeout=120s
kubectl -n app-team-a logs app-a
