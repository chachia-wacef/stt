#!/usr/bin/env bash
# Étape 2 : rôles IAM (quatre Lambdas, state machine, MediaConvert).
set -euo pipefail
source "$(dirname "$0")/common.sh"

BASIC_EXECUTION="arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"

# create_role NOM CONFIANCE MODÈLE_POLITIQUE AVEC_LOGS_LAMBDA(1|0)
create_role() {
  local name="$1" trust="$2" policy_tpl="$3" with_logs="$4"
  if resource_exists aws iam get-role --role-name "$name"; then
    log "Rôle $name : existe déjà (politique mise à jour)"
  else
    log "Rôle $name : création"
    run aws iam create-role --role-name "$name" --assume-role-policy-document "file://$trust" \
      --tags Key=project,Value=stt-poc >/dev/null
  fi
  [ "$with_logs" = "1" ] && run aws iam attach-role-policy --role-name "$name" --policy-arn "$BASIC_EXECUTION"
  render "$policy_tpl" "$BUILD_DIR/$name.policy.json"
  run aws iam put-role-policy --role-name "$name" --policy-name inline --policy-document "file://$BUILD_DIR/$name.policy.json"
}

create_role "$PREFIX-lambda-validate-input"      iam/trust-lambda.json       iam/policy-validate-input.json.tpl      1
create_role "$PREFIX-lambda-submit-mediaconvert" iam/trust-lambda.json       iam/policy-submit-mediaconvert.json.tpl 1
create_role "$PREFIX-lambda-submit-transcribe"   iam/trust-lambda.json       iam/policy-submit-transcribe.json.tpl   1
create_role "$PREFIX-lambda-callback"            iam/trust-lambda.json       iam/policy-callback.json.tpl            1
create_role "$PREFIX-states"                     iam/trust-states.json       iam/policy-states.json.tpl              0
create_role "$MC_ROLE_NAME"                      iam/trust-mediaconvert.json iam/policy-mediaconvert-role.json.tpl   0

# MediaConvert crée sa file « Default » au premier appel de l'API dans la région.
log "File MediaConvert « Default »"
run aws mediaconvert list-queues --query "Queues[].Name" --output text >/dev/null

if [ "${DRY_RUN:-0}" != "1" ]; then
  log "Attente de 15 s : propagation des rôles IAM"
  sleep 15
fi
log "Terminé."
