#!/usr/bin/env bash
# Étape 1 : bucket S3, templates MediaConvert, tables DynamoDB, topic SNS (avec abonnement email).
# Variable requise : ALERT_EMAIL.
set -euo pipefail
source "$(dirname "$0")/common.sh"

if [ -z "${ALERT_EMAIL:-}" ]; then
  if [ "${DRY_RUN:-0}" = "1" ]; then ALERT_EMAIL="equipe@example.com"
  else echo "ERREUR : définir ALERT_EMAIL (adresse qui recevra les alertes). Exemple : export ALERT_EMAIL=moi@exemple.com" >&2; exit 1; fi
fi

# --- Bucket ---
if resource_exists aws s3api head-bucket --bucket "$BUCKET"; then
  log "Bucket $BUCKET : existe déjà (réutilisé, ne sera pas supprimé par destroy.sh)"
else
  log "Bucket $BUCKET : création"
  if [ "$REGION" = "us-east-1" ]; then
    run aws s3api create-bucket --bucket "$BUCKET" >/dev/null
  else
    run aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
      --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
  fi
  save_state BUCKET_CREATED 1
fi

# --- Templates MediaConvert (rôle et file renseignés) ---
log "Templates MediaConvert vers s3://$BUCKET/templates/"
for name in job-mono job-stereo-keep job-stereo-downmix; do
  render "mediaconvert/$name.json.tpl" "$BUILD_DIR/$name.json"
  run aws s3 cp "$BUILD_DIR/$name.json" "s3://$BUCKET/templates/$name.json" --only-show-errors
done

# --- Tables DynamoDB ---
create_table() { # NOM FICHIER_MODÈLE
  if resource_exists aws dynamodb describe-table --table-name "$1"; then
    log "Table $1 : existe déjà"
  else
    log "Table $1 : création"
    render "dynamodb/$2" "$BUILD_DIR/$2.rendered.json"
    run aws dynamodb create-table --cli-input-json "file://$BUILD_DIR/$2.rendered.json" >/dev/null
    run aws dynamodb wait table-exists --table-name "$1"
  fi
}
create_table "$T_TASKS" tasks.json.tpl
create_table "$T_EXECUTIONS" executions.json.tpl

status=$(capture DISABLED aws dynamodb describe-time-to-live --table-name "$T_TASKS" \
  --query TimeToLiveDescription.TimeToLiveStatus --output text)
if [ "$status" != "ENABLED" ] && [ "$status" != "ENABLING" ]; then
  run aws dynamodb update-time-to-live --table-name "$T_TASKS" \
    --time-to-live-specification "Enabled=true,AttributeName=ttl" >/dev/null
fi

# --- Topic SNS ---
log "Topic SNS $TOPIC_NAME"
run aws sns create-topic --name "$TOPIC_NAME" >/dev/null
run aws sns subscribe --topic-arn "$TOPIC_ARN" --protocol email --notification-endpoint "$ALERT_EMAIL" >/dev/null

cat >&2 <<EOF

==> Terminé.
    - Bucket   : $BUCKET
    - Tables   : $T_TASKS, $T_EXECUTIONS
    - Topic SNS: $TOPIC_ARN
    ACTION MANUELLE : ouvrir la boîte de $ALERT_EMAIL et CONFIRMER l'abonnement (message « AWS Notification - Subscription Confirmation »).
    Sans confirmation, aucune alerte n'est reçue.
EOF
