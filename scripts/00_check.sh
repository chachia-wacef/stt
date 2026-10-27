#!/usr/bin/env bash
# Contrôles hors ligne, sans appel AWS : syntaxe des scripts, rendu des modèles, structure de la state machine,
# tests unitaires des Lambdas. À lancer avant le premier déploiement.
set -euo pipefail

export DRY_RUN=1 ACCOUNT_ID=123456789012 AWS_REGION=eu-central-1 PREFIX=stt-poc
source "$(dirname "$0")/common.sh"

errors=0
fail() { echo "ECHEC : $*" >&2; errors=$((errors + 1)); }

log "1/4 Syntaxe des scripts"
for script in scripts/*.sh; do bash -n "$script" || fail "$script"; done

log "2/4 Rendu des modèles et validité JSON"
CHECK_DIR="$BUILD_DIR/check"
mkdir -p "$CHECK_DIR"
for template in mediaconvert/*.tpl dynamodb/*.tpl iam/*.tpl events/*.tpl state_machine/*.tpl; do
  out="$CHECK_DIR/$(basename "$template" .tpl)"
  render "$template" "$out" || fail "rendu $template"
  "$PYTHON" -c "import json,sys; json.load(open(sys.argv[1], encoding='utf-8'))" "$out" || fail "JSON invalide : $template"
done
for json in iam/trust-*.json events/mediaconvert-pattern.json; do
  "$PYTHON" -c "import json,sys; json.load(open(sys.argv[1], encoding='utf-8'))" "$json" || fail "JSON invalide : $json"
done

log "3/4 Structure de la state machine"
"$PYTHON" scripts/check_asl.py "$CHECK_DIR/pipeline.asl.json" || fail "state machine"

log "4/4 Tests unitaires (Lambdas et affichage de la transcription)"
if "$PYTHON" -c "import boto3" >/dev/null 2>&1; then
  for dir in validate_input submit_mediaconvert submit_transcribe callback; do
    (cd "lambdas/$dir" && PYTHONDONTWRITEBYTECODE=1 "$PYTHON" -m unittest discover -s tests >/dev/null 2>&1) \
      && echo "  ok : $dir" || fail "tests de $dir"
  done
else
  echo "  boto3 non installé : tests des Lambdas ignorés (pip install boto3 pour les exécuter)"
fi
(cd scripts && PYTHONDONTWRITEBYTECODE=1 "$PYTHON" -m unittest test_show_transcript >/dev/null 2>&1) \
  && echo "  ok : show_transcript" || fail "tests de show_transcript"

rm -rf "$CHECK_DIR"
if [ "$errors" -gt 0 ]; then echo "$errors contrôle(s) en échec." >&2; exit 1; fi
log "Tous les contrôles sont passés."
