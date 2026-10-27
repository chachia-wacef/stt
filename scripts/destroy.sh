#!/usr/bin/env bash
# Supprime TOUTES les ressources créées par le POC (state machine, règles, Lambdas, layer, tables, topic, rôles, logs,
# et le contenu du bucket).
#
# Usage : scripts/destroy.sh [--yes]
#   Sans --yes, le script demande de retaper le préfixe du POC pour confirmer.
#
# Le bucket n'est supprimé que s'il a été créé par ce POC. S'il existait déjà (POC_BUCKET), seuls les
# préfixes templates/, layers/, output/, transcripts/ et input/demo/ sont vidés.
set -euo pipefail
source "$(dirname "$0")/common.sh"

if [ "${1:-}" != "--yes" ] && [ "${DRY_RUN:-0}" != "1" ]; then
  echo "Cette opération supprime les ressources « $PREFIX » du compte $ACCOUNT_ID (région $REGION) et vide le bucket $BUCKET."
  read -r -p "Retaper le préfixe ($PREFIX) pour confirmer : " answer
  [ "$answer" = "$PREFIX" ] || { echo "Annulé."; exit 1; }
fi

try() { # tolère l'absence de la ressource
  if [ "${DRY_RUN:-0}" = "1" ]; then printf '+ %s\n' "$*" >&2; return 0; fi
  if "$@" >/dev/null 2>&1; then log "ok : $*"; else log "(ignoré) : $1 $2 $3"; fi
}

log "Règles EventBridge"
for rule in "$PREFIX-mediaconvert-job-state" "$PREFIX-transcribe-job-state"; do
  try aws events remove-targets --rule "$rule" --ids callback
  try aws events delete-rule --name "$rule"
done

log "State machine"
try aws stepfunctions delete-state-machine --state-machine-arn "$SM_ARN"

log "Lambdas"
for fn in validate-input submit-mediaconvert submit-transcribe callback; do
  try aws lambda delete-function --function-name "$PREFIX-$fn"
done

log "Layer"
if [ "${DRY_RUN:-0}" != "1" ]; then
  for version in $(aws lambda list-layer-versions --layer-name "$PREFIX-ffprobe" --query "LayerVersions[].Version" --output text 2>/dev/null || true); do
    try aws lambda delete-layer-version --layer-name "$PREFIX-ffprobe" --version-number "$version"
  done
fi

log "Groupes de logs"
for fn in validate-input submit-mediaconvert submit-transcribe callback; do
  try awsnc logs delete-log-group --log-group-name "/aws/lambda/$PREFIX-$fn"
done
try awsnc logs delete-log-group --log-group-name "$SM_LOG_GROUP"

log "Tables DynamoDB"
try aws dynamodb delete-table --table-name "$T_TASKS"
try aws dynamodb delete-table --table-name "$T_EXECUTIONS"

log "Topic SNS"
try aws sns delete-topic --topic-arn "$TOPIC_ARN"

log "Rôles IAM"
for role in "$PREFIX-lambda-validate-input" "$PREFIX-lambda-submit-mediaconvert" "$PREFIX-lambda-submit-transcribe" \
            "$PREFIX-lambda-callback" "$PREFIX-states" "$MC_ROLE_NAME"; do
  try aws iam detach-role-policy --role-name "$role" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
  try aws iam delete-role-policy --role-name "$role" --policy-name inline
  try aws iam delete-role --role-name "$role"
done

log "Contenu S3"
if [ "${BUCKET_CREATED:-0}" = "1" ]; then
  try aws s3 rb "s3://$BUCKET" --force
else
  for prefix in templates layers output transcripts input/demo; do
    try aws s3 rm "s3://$BUCKET/$prefix/" --recursive
  done
fi

if [ "${DRY_RUN:-0}" != "1" ]; then
  rm -rf "$BUILD_DIR" "$STATE_FILE"
fi
log "Terminé. Les files d'attente MediaConvert et les jobs terminés ne sont pas supprimables (aucun coût)."
