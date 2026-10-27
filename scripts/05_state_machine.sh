#!/usr/bin/env bash
# Étape 5 : crée (ou met à jour) la state machine avec journalisation CloudWatch.
# Prérequis : 01_storage.sh (tables, topic), 02_iam.sh, 04_lambdas.sh.
set -euo pipefail
source "$(dirname "$0")/common.sh"

DEFINITION="$BUILD_DIR/pipeline.asl.json"
ROLE_ARN="arn:aws:iam::$ACCOUNT_ID:role/$PREFIX-states"
LOGGING="{\"level\":\"ERROR\",\"includeExecutionData\":false,\"destinations\":[{\"cloudWatchLogsLogGroup\":{\"logGroupArn\":\"arn:aws:logs:$REGION:$ACCOUNT_ID:log-group:$SM_LOG_GROUP:*\"}}]}"

render state_machine/pipeline.asl.json.tpl "$DEFINITION"
log "Contrôle de la structure de la définition"
"$PYTHON" scripts/check_asl.py "$DEFINITION"

log "Groupe de logs $SM_LOG_GROUP"
if [ "${DRY_RUN:-0}" = "1" ]; then
  run awsnc logs create-log-group --log-group-name "$SM_LOG_GROUP"
else
  awsnc logs create-log-group --log-group-name "$SM_LOG_GROUP" >/dev/null 2>&1 || log "(groupe de logs déjà présent)"
fi
run awsnc logs put-retention-policy --log-group-name "$SM_LOG_GROUP" --retention-in-days 14

if resource_exists aws stepfunctions describe-state-machine --state-machine-arn "$SM_ARN"; then
  log "State machine $SM_NAME : mise à jour"
  run awsnc stepfunctions update-state-machine --state-machine-arn "$SM_ARN" \
    --definition "file://$DEFINITION" --role-arn "$ROLE_ARN" --logging-configuration "$LOGGING" >/dev/null
else
  log "State machine $SM_NAME : création"
  retry 6 run awsnc stepfunctions create-state-machine --name "$SM_NAME" --type STANDARD \
    --definition "file://$DEFINITION" --role-arn "$ROLE_ARN" --logging-configuration "$LOGGING" \
    --tags key=project,value=stt-poc >/dev/null
fi

log "Terminé. ARN : $SM_ARN"
log "Console : https://$REGION.console.aws.amazon.com/states/home?region=$REGION#/statemachines/view/$SM_ARN"
