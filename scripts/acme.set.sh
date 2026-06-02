"/home/ecs-user/.acme.sh"/acme.sh --install-cert -d caringfamily.cn --ecc \
  --reloadcmd "kubectl create secret tls https-server-secret --cert=/home/ecs-user/.acme.sh/caringfamily.cn_ecc/fullchain.cer --key=/home/ecs-user/.acme.sh/caringfamily.cn_ecc/caringfamily.cn.key -n higress-system --dry-run=client -o yaml | kubectl apply -f -"

ACME_ACCOUNT_CONF="$HOME/.acme.sh/account.conf"
export Ali_Key=$(grep "^SAVED_Ali_Key=" "$ACME_ACCOUNT_CONF" | sed 's/^SAVED_Ali_Key=//; s/^["'\''"]//; s/["'\''"]$//')
export Ali_Secret=$(grep "^SAVED_Ali_Secret=" "$ACME_ACCOUNT_CONF" | sed 's/^SAVED_Ali_Secret=//; s/^["'\''"]//; s/["'\''"]$//')

"/home/ecs-user/.acme.sh"/acme.sh --deploy -d res.caringfamily.cn --ecc --deploy-hook ali_cdn