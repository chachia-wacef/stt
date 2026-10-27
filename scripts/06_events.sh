#!/usr/bin/env bash
# Étape 6 : deux règles EventBridge (fin de job MediaConvert, fin de job Transcribe) vers la Lambda de rappel.
# Prérequis : 04_lambdas.sh.
set -euo pipefail
source "$(dirname "$0")/common.sh"

CALLBACK_NAME="$PREFIX-callback"
CALLBACK_ARN="arn:aws:lambda:$REGION:$ACCOUNT_ID:function:$CALLBACK_NAME"

setup_rule() { # NOM_RÈGLE FICHIER_MOTIF IDENTIFIANT_DROIT
  local rule="$1" pattern="$2" statement="$3"
  render "$pattern" "$BUILD_DIR/$rule.pattern.json"
  cat > "$BUILD_DIR/$rule.targets.json" <<EOF
[{
  "Id": "callback",
  "Arn": "$CALLBACK_ARN",
  "RetryPolicy": { "MaximumRetryAttempts": 2, "MaximumEventAgeInSeconds": 3600 }
}]
EOF
  log "Règle $rule"
  run aws events put-rule --name "$rule" --event-pattern "file://$BUILD_DIR/$rule.pattern.json" \
    --description "STT POC : fin de job vers $CALLBACK_NAME" >/dev/null
  run aws events put-targets --rule "$rule" --targets "file://$BUILD_DIR/$rule.targets.json" >/dev/null
  if [ "${DRY_RUN:-0}" = "1" ]; then
    run aws lambda add-permission --function-name "$CALLBACK_NAME" --statement-id "$statement" \
      --action lambda:InvokeFunction --principal events.amazonaws.com \
      --source-arn "arn:aws:events:$REGION:$ACCOUNT_ID:rule/$rule"
  else
    aws lambda add-permission --function-name "$CALLBACK_NAME" --statement-id "$statement" \
      --action lambda:InvokeFunction --principal events.amazonaws.com \
      --source-arn "arn:aws:events:$REGION:$ACCOUNT_ID:rule/$rule" >/dev/null 2>&1 \
      || log "(droit d'invocation $statement déjà présent)"
  fi
}

# Le motif MediaConvert n'a pas de marqueur : copié tel quel.
cp events/mediaconvert-pattern.json "$BUILD_DIR/mediaconvert-pattern.json.tpl"
setup_rule "$PREFIX-mediaconvert-job-state" "$BUILD_DIR/mediaconvert-pattern.json.tpl" events-mediaconvert
setup_rule "$PREFIX-transcribe-job-state" events/transcribe-pattern.json.tpl events-transcribe

log "Terminé. Le pipeline est prêt : lancer scripts/run_demo.sh <fichier audio>."
