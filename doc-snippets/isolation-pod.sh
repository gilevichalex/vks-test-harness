# Verbatim copy of the snippet in the public reference architecture (do not edit here; edit the doc, then re-copy).
BUCKET_A=$(kubectl get bucket \
  $(kubectl -n app-team-a get bucketclaim app-bucket -o jsonpath='{.status.bucketName}') \
  -o jsonpath='{.status.bucketID}')

kubectl -n app-team-b apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: isolation-check
spec:
  restartPolicy: Never
  securityContext: {runAsNonRoot: true, runAsUser: 1000, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: check
      image: public.ecr.aws/aws-cli/aws-cli:2.17.0
      env:
        - {name: HOME, value: /tmp}
        - {name: OTHER_BUCKET, value: "${BUCKET_A}"}
      command: ["/bin/bash", "-c"]
      args:
        - |
          INFO=\$(cat /cosi/BucketInfo)
          get() { echo "\$INFO" | grep -o "\\"\$1\\": *\\"[^\\"]*\\"" | head -1 | sed 's/.*: *"\\(.*\\)"/\\1/'; }
          export AWS_ACCESS_KEY_ID=\$(get accessKeyID) AWS_SECRET_ACCESS_KEY=\$(get accessSecretKey) AWS_DEFAULT_REGION=us-east-1
          aws configure set default.s3.addressing_style path
          if aws --endpoint-url "\$(get endpoint)" s3 ls "s3://\$OTHER_BUCKET/"; then echo "FAIL: access allowed"; else echo "OK: access denied"; fi
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
      volumeMounts: [{name: cosi, mountPath: /cosi, readOnly: true}]
  volumes: [{name: cosi, secret: {secretName: app-bucket-b-creds}}]
EOF

kubectl -n app-team-b wait pod/isolation-check --for=jsonpath='{.status.phase}'=Succeeded --timeout=120s
kubectl -n app-team-b logs isolation-check | tail -1      # OK: access denied
