source /scripts/common.sh
echo "IAM users in the account (COSI creates one 'ba-<uuid>' per BucketAccess):"
iam list-users --query 'Users[].[UserName,CreateDate]' --output text
