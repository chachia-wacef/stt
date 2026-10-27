#!/usr/bin/env bash
# Provoque puis annule une panne technique, pour montrer l'alerte par email.
#
# Usage :
#   scripts/demo_failure.sh break   casse la Lambda de validation (erreur au chargement du code)
#   scripts/demo_failure.sh fix     rétablit la configuration normale
#
# Après « break », lancer scripts/run_demo.sh avec n'importe quel fichier : l'exécution échoue tout de suite
# à l'étape de validation (échec technique), un email est envoyé, le statut passe à FAILED avec un message générique.
# Penser à lancer « fix » ensuite.
set -euo pipefail
source "$(dirname "$0")/common.sh"

FN="$PREFIX-validate-input"
case "${1:-}" in
  break)
    log "Configuration invalide sur $FN (NOT_FOUND_RETRIES=oops)"
    run aws lambda update-function-configuration --function-name "$FN" \
      --environment "$(env_json "ALLOWED_BUCKETS=$BUCKET" "NOT_FOUND_RETRIES=oops")" >/dev/null
    run aws lambda wait function-updated --function-name "$FN"
    log "Panne activée. Lancer run_demo.sh, puis « demo_failure.sh fix »." ;;
  fix)
    log "Rétablissement de la configuration de $FN"
    run aws lambda update-function-configuration --function-name "$FN" --environment "$(lambda_env validate)" >/dev/null
    run aws lambda wait function-updated --function-name "$FN"
    log "Configuration normale rétablie." ;;
  *)
    sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
