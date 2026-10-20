# ARG1 bucket-name prefix, ARG2 bucket to keep
source /scripts/common.sh
for b in $(s3a list-buckets --query 'Buckets[].Name' --output text | tr '\t' '\n' | grep "^$ARG1"); do
  [[ $b == "${ARG2:-}" ]] && { echo "keep $b"; continue; }
  s3 rm "s3://$b" --recursive --only-show-errors; s3a delete-bucket --bucket "$b" && ok "removed $b"
done
exit 0
