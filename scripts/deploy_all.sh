#!/usr/bin/env bash
# Déploie tout le POC, dans l'ordre. Équivalent à lancer 01 à 06 l'un après l'autre.
#
# Prérequis : AWS CLI v2 configurée, Python 3.8+, variable ALERT_EMAIL définie.
# Simulation (aucune commande AWS exécutée) : DRY_RUN=1 scripts/deploy_all.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

for step in 01_storage 02_iam 03_layer 04_lambdas 05_state_machine 06_events; do
  echo
  echo "################ $step ################"
  bash "$here/$step.sh"
done

source "$here/common.sh"
cat >&2 <<EOF

==> POC déployé.
    1. Confirmer l'abonnement email SNS si ce n'est pas encore fait.
    2. Lancer une démonstration :  scripts/run_demo.sh <fichier audio>
    3. Panne volontaire (email) :  scripts/demo_failure.sh break  /  fix
    4. Tout supprimer :            scripts/destroy.sh
EOF
