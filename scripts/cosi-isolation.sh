# ARG1 = another namespace's bucket; these credentials must NOT read or write it.
source /scripts/common.sh
cosi_env
if s3 ls "s3://$ARG1/" >/dev/null 2>&1; then bad "LIST on foreign bucket $ARG1 allowed"; else ok "LIST on foreign bucket $ARG1 denied"; fi
if echo x | s3 cp - "s3://$ARG1/intruder.txt" >/dev/null 2>&1; then bad "PUT on foreign bucket allowed"; else ok "PUT on foreign bucket $ARG1 denied"; fi
