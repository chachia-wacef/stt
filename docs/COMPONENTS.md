# Composants du POC

Détail technique de chaque ressource créée par `scripts/deploy_all.sh`. `<PREFIX>` vaut `stt-poc` par défaut.

## 1. Vue d'ensemble des ressources

| Type | Nom | Créé par |
|---|---|---|
| Bucket S3 | `<PREFIX>-<compte>-<région>` (ou `POC_BUCKET`) | `01_storage.sh` |
| Tables DynamoDB | `<PREFIX>-executions`, `<PREFIX>-tasks` | `01_storage.sh` |
| Topic SNS | `<PREFIX>-alerts` | `01_storage.sh` |
| Rôles IAM | `<PREFIX>-lambda-validate-input`, `-lambda-submit-mediaconvert`, `-lambda-submit-transcribe`, `-lambda-callback`, `<PREFIX>-states`, `<PREFIX>-mediaconvert` | `02_iam.sh` |
| Layer | `<PREFIX>-ffprobe` | `03_layer.sh` |
| Lambdas | `<PREFIX>-validate-input`, `-submit-mediaconvert`, `-submit-transcribe`, `-callback` | `04_lambdas.sh` |
| State machine | `<PREFIX>-pipeline` (Standard) | `05_state_machine.sh` |
| Règles EventBridge | `<PREFIX>-mediaconvert-job-state`, `<PREFIX>-transcribe-job-state` | `06_events.sh` |
| Groupes de logs | `/aws/lambda/<PREFIX>-*`, `/aws/vendedlogs/states/<PREFIX>-pipeline` | `04`, `05` |

## 2. Principes de fonctionnement

| Principe | Mise en œuvre |
|---|---|
| Identifiant maître | `execution_id` (UUID) : nom de l'exécution, étiquette du job MediaConvert (`UserMetadata`), nom du job Transcribe (`<PREFIX>-<execution_id>`), clé des tables |
| Attente par jeton (`waitForTaskToken`) | Pour MediaConvert et Transcribe, la state machine transmet son jeton à la Lambda, qui le range dans `<PREFIX>-tasks` puis lance le job. À la fin du job, la Lambda de rappel retrouve le jeton et réveille la state machine |
| Jeton écrit avant le job | Évite qu'un événement de fin très rapide arrive avant l'enregistrement du jeton |
| Échec lié au fichier ou échec technique | Le premier met le statut à `FAILED` avec un message, sans alerte ; le second envoie un email et ne montre qu'un message générique dans le suivi |
| Idempotence | Événements en double ignorés, jeton périmé nettoyé, job Transcribe déjà existant réutilisé |

## 3. Données

### 3.1 S3

| Préfixe | Contenu | Écrit par |
|---|---|---|
| `input/demo/` | Fichiers envoyés par `run_demo.sh` | vous |
| `templates/` | Trois templates de job MediaConvert (rôle et file renseignés) | `01_storage.sh` |
| `layers/` | Archive de la layer ffprobe (transit pour la publication) | `03_layer.sh` |
| `output/<execution_id>/` | `<nom>_flac48k_<mono\|stereo\|mono_downmix>.flac` et `<nom>_playback.mp4` | MediaConvert |
| `transcripts/<execution_id>/transcript.json` | Transcription au format JSON de Transcribe | Transcribe |

### 3.2 `<PREFIX>-executions` (clé : `execution_id`)

Suivi de chaque traitement, utile pour la démonstration.

| Attribut | Écrit par | Contenu |
|---|---|---|
| `status` | state machine | `PENDING` (écrit par `run_demo.sh`), `VALIDATING`, `TRANSCODING`, `TRANSCRIBING`, `DONE`, `FAILED` |
| `updated_at`, `created_at`, `owner`, `input` | state machine, `run_demo.sh` | Horodatages, origine, fichier d'entrée |
| `mediaconvert_job_id` | Lambda de transcodage | Identifiant du job MediaConvert |
| `transcribe_job_name` | Lambda de transcription | Nom du job Transcribe |
| `outputs` | state machine (fin) | `flac`, `playback`, `transcript` (chemins S3) |
| `error` | state machine (échec) | `code` et `message` |

### 3.3 `<PREFIX>-tasks` (clés : `execution_id` + `stage`)

Jetons en attente. `stage` vaut `MEDIACONVERT` ou `TRANSCRIBE`. Attributs : `task_token`, `created_at`, `ttl` (suppression automatique après 24 h), plus le contexte nécessaire au rappel (`channels`, `template`, `transcript_uri`...). Une ligne n'existe que pendant l'attente d'un job.

## 4. Lambdas

Toutes en Python 3.12. Le code est dans `lambdas/<nom>/lambda_function.py`, les tests dans `lambdas/<nom>/tests/`.

| Lambda | Rôle | Timeout / mémoire | Variables d'environnement |
|---|---|---|---|
| `validate-input` | Vérifie l'URI, le bucket, l'extension, l'existence et la taille du fichier. Erreurs : `InputNotFound`, `InputInvalid` | 30 s / 128 Mo | `ALLOWED_BUCKETS` |
| `submit-mediaconvert` | Détecte les canaux avec `ffprobe`, choisit le template, enregistre le jeton, crée le job MediaConvert. Erreurs liées au fichier : `NoAudioStream`, `UnsupportedChannels`, `InputInvalid`, `InvalidParameters` | 90 s / 512 Mo + layer | `TEMPLATES_BUCKET`, `OUTPUT_BUCKET`, `TASKS_TABLE`, `EXECUTIONS_TABLE`, `MEDIACONVERT_ROLE_ARN`, `MEDIACONVERT_QUEUE_ARN` |
| `submit-transcribe` | Construit la requête Transcribe, enregistre le jeton, lance le job sur le FLAC | 30 s / 128 Mo | `OUTPUT_BUCKET`, `ALLOWED_BUCKETS`, `TASKS_TABLE`, `EXECUTIONS_TABLE`, `TRANSCRIBE_JOB_PREFIX` |
| `callback` | Reçoit les événements de fin de job, retrouve le jeton, appelle `SendTaskSuccess` ou `SendTaskFailure` | 30 s / 128 Mo | `TASKS_TABLE`, `TRANSCRIBE_JOB_PREFIX` |

Les valeurs par défaut écrites dans le code (par exemple le nom de bucket `stt-tests-wacef`) viennent du projet d'origine et servent aux tests unitaires. Elles sont **toujours remplacées** par les variables d'environnement que `04_lambdas.sh` définit à chaque déploiement.

### Entrées attendues

- State machine (démarrage) :

```json
{
  "execution_id": "<uuid>",
  "owner": "poc",
  "input": "s3://<bucket>/input/demo/mon-fichier.mp3",
  "stereo_mode": "downmix",
  "transcribe": { "language_code": "fr-FR" }
}
```

`transcribe` accepte : `language_code` **ou** `identify_language` (avec `language_options` facultatif), `max_speaker_labels` (2 à 30), `vocabulary_name`.

### Choix du template MediaConvert

| Entrée | `stereo_mode` | Template | FLAC produit |
|---|---|---|---|
| mono | (ignoré) | `job-mono` | 1 canal |
| stéréo | `downmix` | `job-stereo-downmix` | 1 canal (fusion des deux canaux, −3 dB chacun) |
| stéréo | `keep` | `job-stereo-keep` | 2 canaux, avec identification de canaux dans Transcribe |

`keep` avec `max_speaker_labels` est refusé (l'identification de canaux et la diarisation sont incompatibles). Plus de 2 canaux, ou aucune piste audio : échec lié au fichier.

### Sorties MediaConvert

| Sortie | Format |
|---|---|
| FLAC | 16 bits, 48 kHz, conteneur `RAW`, sans normalisation du volume : entrée de Transcribe |
| MP4 | AAC 128 kbit/s, 48 kHz, index en tête de fichier : lecture dans une application |

## 5. State machine

Définition : `state_machine/pipeline.asl.json.tpl`. Type Standard, durée maximale 1 h.

| État | Détail |
|---|---|
| `SetStatusValidating` / `SetStatusTranscoding` / `SetStatusTranscribing` | Met à jour `status` dans `<PREFIX>-executions` (intégration DynamoDB native, sans Lambda) |
| `ValidateInput` | Lambda de validation ; résultat conservé dans `$.validation` |
| `SubmitMediaConvert` | Lambda + attente de jeton, **15 minutes** maximum ; résultat du rappel dans `$.mediaconvert` |
| `SubmitTranscribe` | Lambda + attente de jeton, **30 minutes** maximum ; résultat du rappel dans `$.transcription` |
| `Finalize` | `status = DONE` et `outputs` ; l'exécution se termine en `Succeeded` |
| Échec lié au fichier | `InputNotFound`, `InputInvalid`, `InvalidParameters`, `NoAudioStream`, `UnsupportedChannels` : statut `FAILED` avec code et message ; l'exécution se termine en `Succeeded`, sans alerte |
| Échec technique | Toute autre erreur : statut `FAILED` générique, **email SNS** (erreur, cause, lien vers l'exécution), l'exécution se termine en `Failed` |

Nouvelles tentatives : erreurs transitoires des Lambdas et des appels DynamoDB/SNS (3 essais). Un job MediaConvert ou Transcribe en échec n'est jamais rejoué.

Une exécution marquée « réussie » peut donc contenir un statut métier `FAILED` : c'est voulu, pour que seuls les vrais incidents comptent comme exécutions en échec.

## 6. Règles EventBridge

| Règle | Motif | Cible |
|---|---|---|
| `<PREFIX>-mediaconvert-job-state` | Source `aws.mediaconvert`, `MediaConvert Job State Change`, statuts `COMPLETE`/`ERROR`/`CANCELED`, présence de `userMetadata.execution_id` (ignore les jobs étrangers) | Lambda `callback` |
| `<PREFIX>-transcribe-job-state` | Source `aws.transcribe`, `Transcribe Job State Change`, statuts `COMPLETED`/`FAILED`, nom de job commençant par `<PREFIX>-` | Lambda `callback` |

Pourquoi une Lambda entre EventBridge et Step Functions : EventBridge ne sait pas appeler `SendTaskSuccess` directement.

## 7. Rôles IAM

Un rôle par composant, droits limités aux ressources du POC (politiques dans `iam/`).

| Rôle | Droits principaux |
|---|---|
| `lambda-validate-input` | Lecture du bucket (`HeadObject`) |
| `lambda-submit-mediaconvert` | Lecture du bucket, `mediaconvert:CreateJob` (sur toutes ressources dans le POC), `iam:PassRole` vers le rôle MediaConvert uniquement, écriture dans les deux tables, `states:SendTaskFailure` |
| `lambda-submit-transcribe` | `transcribe:StartTranscriptionJob`, lecture de `output/`, écriture dans `transcripts/`, écriture dans les deux tables, `states:SendTaskFailure` |
| `lambda-callback` | Lecture et suppression dans la table des jetons, `states:SendTaskSuccess` / `SendTaskFailure` |
| `states` | Invocation des trois Lambdas, mise à jour de la table de suivi, publication sur le topic, écriture des logs |
| `mediaconvert` | Lecture et écriture dans le bucket (rôle assumé par le service MediaConvert) |

Les Lambdas ont aussi la politique gérée `AWSLambdaBasicExecutionRole` (journaux).

## 8. Différences avec une version de production

| Sujet | POC | Production prévue |
|---|---|---|
| Délais d'attente | 15 min / 30 min / 1 h | 1 h / 2 h / 4 h |
| Droit `CreateJob` | toutes ressources | limité à la file utilisée (à valider) |
| Événement de fin perdu | l'exécution expire au délai | file d'attente d'échec + alarme |
| Tables | sans protection contre la suppression, sans flux | protégées, flux activé, sauvegarde |
| Topic d'alertes | un seul | critique / avertissement |
| Observabilité | logs + email | alarmes, tableau de bord, budgets |
| Accès | démarrage par script ou console | API authentifiée, envoi de fichiers présigné, notifications |
