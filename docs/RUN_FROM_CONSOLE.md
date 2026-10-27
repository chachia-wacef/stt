# Lancer un traitement depuis la console Step Functions

Ce guide explique comment démarrer une exécution **à la main**, avec un fichier **déjà présent dans S3**, sans passer par `scripts/run_demo.sh`. Utile pour rejouer un fichier existant, tester des paramètres précis, ou montrer le fonctionnement dans la console pendant une présentation.

## 1. Prérequis

| Besoin | Détail |
|---|---|
| POC déployé | La state machine `stt-poc-pipeline` existe (voir le README) |
| Fichier dans le bucket du POC | Le POC ne lit que son propre bucket : `stt-poc-<compte>-<région>` (par exemple `stt-poc-127214194449-eu-central-1`). Un fichier situé dans un autre bucket doit d'abord y être copié (section 2) |
| Extension reconnue | `mp3`, `wav`, `flac`, `m4a`, `aac`, `ogg`, `opus`, `wma`, `amr`, `mp4`, `m4v`, `mov`, `mkv`, `webm`, `avi`, `mpg`, `mpeg`, `3gp`, `ts` |
| Fichier non vide | Un fichier de 0 octet est refusé |
| Région de la console | Celle du déploiement (par exemple Francfort, `eu-central-1`) : vérifier le sélecteur de région en haut à droite |

## 2. Placer le fichier dans le bucket du POC

### Fichier déjà dans le bucket du POC

Rien à faire. Noter sa clé complète, par exemple `input/demo/mon-fichier.mp3`.

### Fichier dans un autre bucket

Copie côté S3, sans téléchargement local (Git Bash) :

```bash
aws s3 cp s3://stt-tests-wacef/input/exp3.mp3 s3://stt-poc-127214194449-eu-central-1/input/demo/exp3.mp3
```

Dans la console : **S3** > le bucket source > cocher le fichier > *Actions* > *Copy* > choisir le bucket du POC et le dossier `input/demo/`.

### Fichier local

Console **S3** > bucket du POC > `input/demo/` (le créer au besoin) > *Upload*. Ou, en CLI :

```bash
aws s3 cp mon-fichier.mp3 s3://stt-poc-127214194449-eu-central-1/input/demo/mon-fichier.mp3
```

## 3. Préparer l'entrée (JSON)

### Modèle de base

```json
{
  "execution_id": "demo-20261027-1",
  "input": "s3://stt-poc-127214194449-eu-central-1/input/demo/mon-fichier.mp3",
  "stereo_mode": "downmix",
  "transcribe": {
    "language_code": "fr-FR"
  }
}
```

### Description des champs

| Champ | Obligatoire | Valeur |
|---|---|---|
| `execution_id` | **oui** | Identifiant **unique** de ce traitement (voir l'avertissement ci-dessous). Caractères autorisés : lettres, chiffres, `.`, `_`, `-` (il sert à nommer le job Transcribe). Il détermine aussi le dossier de sortie `output/<execution_id>/` et la ligne de suivi dans DynamoDB |
| `input` | **oui** | Adresse S3 du fichier, **dans le bucket du POC** : `s3://<bucket>/<clé>` |
| `stereo_mode` | **oui** | `downmix` : fusionne les deux canaux d'un fichier stéréo en un seul. `keep` : conserve les deux canaux (identification de canaux). Sans effet pour un fichier mono, mais le champ doit être présent |
| `transcribe` | **oui** | Options de transcription, voir ci-dessous. Doit contenir au moins la langue |
| `owner` | non | Ignoré par la state machine du POC |

Options de `transcribe` (une seule des deux options de langue) :

| Option | Valeur | Remarque |
|---|---|---|
| `language_code` | `"fr-FR"`, `"en-US"`... | Langue connue à l'avance |
| `identify_language` | `true` | Détection automatique de la langue (au lieu de `language_code`) |
| `language_options` | `["fr-FR", "en-US"]` | Avec `identify_language` seulement : restreint les langues candidates |
| `max_speaker_labels` | entier de 2 à 30 | Active la diarisation (« qui parle »). **Incompatible** avec `stereo_mode: keep` sur un fichier stéréo |
| `vocabulary_name` | nom | Vocabulaire personnalisé Transcribe qui doit déjà exister dans la région |

### Exemples

**Deux locuteurs dans un fichier mono ou fusionné :**

```json
{
  "execution_id": "demo-20261027-2",
  "input": "s3://stt-poc-127214194449-eu-central-1/input/demo/dialogue.mp3",
  "stereo_mode": "downmix",
  "transcribe": { "language_code": "fr-FR", "max_speaker_labels": 2 }
}
```

**Stéréo avec un locuteur par canal (appel téléphonique, par exemple) :**

```json
{
  "execution_id": "demo-20261027-3",
  "input": "s3://stt-poc-127214194449-eu-central-1/input/demo/appel.wav",
  "stereo_mode": "keep",
  "transcribe": { "language_code": "fr-FR" }
}
```

**Détection automatique de la langue :**

```json
{
  "execution_id": "demo-20261027-4",
  "input": "s3://stt-poc-127214194449-eu-central-1/input/demo/inconnu.mp3",
  "stereo_mode": "downmix",
  "transcribe": { "identify_language": true, "language_options": ["fr-FR", "en-US"] }
}
```

### Avertissement : un `execution_id` neuf à chaque essai

Ne **jamais** réutiliser un `execution_id` déjà employé :

- le job Transcribe porte ce nom et Transcribe refuse deux jobs de même nom ;
- si le job existe déjà et est terminé, la Lambda le réutilise sans erreur, **aucun nouvel événement de fin n'arrive**, et l'exécution reste bloquée en `TRANSCRIBING` jusqu'à l'expiration du délai (30 minutes) ;
- les fichiers de `output/<execution_id>/` et la ligne DynamoDB seraient écrasés.

Pour générer un identifiant unique :

```bash
python -c "import uuid; print(uuid.uuid4())"            # Git Bash
```

```powershell
[guid]::NewGuid().ToString()                            # PowerShell
```

Ou simplement un compteur daté : `demo-20261027-1`, `demo-20261027-2`...

## 4. Démarrer l'exécution dans la console

1. Ouvrir la console AWS, vérifier la **région** (en haut à droite).
2. **Step Functions** > *State machines* > cliquer sur **`stt-poc-pipeline`**.
3. Bouton **Start execution** (en haut à droite).
4. Dans la fenêtre :
   - *Name* : laisser vide (un nom est généré) ou saisir un nom unique. Ce nom est sans rapport avec `execution_id`.
   - *Input* : **effacer** le contenu par défaut et coller votre JSON.
5. **Start execution**.

La console ouvre la page de l'exécution. Elle affiche une erreur de validation si le JSON est mal formé (virgule en trop, guillemets).

## 5. Suivre l'exécution

### Le graphe

Onglet **Graph view** : chaque état se colore au fur et à mesure.

| Couleur | Signification |
|---|---|
| Bleu | En cours |
| Vert | Réussi |
| Rouge | Échec |
| Gris | Pas encore atteint |

Déroulement normal : `SetStatusValidating` > `ValidateInput` > `SetStatusTranscoding` > `SubmitMediaConvert` > `SetStatusTranscribing` > `SubmitTranscribe` > `Finalize` > `Done`.

`SubmitMediaConvert` et `SubmitTranscribe` restent **bleus** pendant que le job tourne : la state machine est en pause (attente du rappel). C'est normal et gratuit.

### Le détail d'une étape

Cliquer sur un état du graphe : panneau de droite avec **Input**, **Output** et, en cas d'erreur, **Error** et **Cause**. L'onglet **Execution event history** donne la chronologie complète.

### Le statut métier

Console **DynamoDB** > *Tables* > `stt-poc-executions` > *Explore table items*. Chercher la ligne dont `execution_id` correspond à votre identifiant :

| `status` | Étape |
|---|---|
| `VALIDATING` | Vérification du fichier |
| `TRANSCODING` | Job MediaConvert en cours |
| `TRANSCRIBING` | Job Transcribe en cours |
| `DONE` | Terminé, `outputs` renseigné |
| `FAILED` | Échec, `error` renseigné |

Cette ligne contient moins d'informations que lors d'un lancement avec `run_demo.sh` (pas de `input` ni de `created_at` : ils sont écrits par le script). Cela n'a pas d'effet sur le traitement.

### Les services sous-jacents

- **MediaConvert** > *Jobs* : le job de transcodage (métadonnée `execution_id`).
- **Transcribe** > *Transcription jobs* : le job nommé `stt-poc-<execution_id>`.

## 6. Trouver les résultats

Console **S3** > bucket du POC :

| Emplacement | Contenu |
|---|---|
| `output/<execution_id>/` | `<nom>_flac48k_<mono\|stereo\|mono_downmix>.flac` (entrée de Transcribe) et `<nom>_playback.mp4` (lecture) |
| `transcripts/<execution_id>/transcript.json` | La transcription au format JSON de Transcribe |

Le chemin exact des trois fichiers est aussi dans l'attribut `outputs` de la ligne DynamoDB, et dans l'onglet **Execution output** de l'exécution Step Functions (après `Finalize`).

### Lire la transcription

Dans le JSON, le texte complet est à `results.transcripts[0].transcript`. Pour un affichage lisible, y compris par locuteur ou par canal (Git Bash, dossier `poc`) :

```bash
aws s3 cp s3://stt-poc-127214194449-eu-central-1/transcripts/demo-20261027-1/transcript.json - | python scripts/show_transcript.py
```

## 7. Variante en ligne de commande

Équivalent de la console, avec le JSON enregistré dans un fichier (Git Bash) :

```bash
cat > entree.json <<'EOF'
{
  "execution_id": "demo-20261027-1",
  "input": "s3://stt-poc-127214194449-eu-central-1/input/demo/mon-fichier.mp3",
  "stereo_mode": "downmix",
  "transcribe": { "language_code": "fr-FR" }
}
EOF

aws stepfunctions start-execution \
  --state-machine-arn arn:aws:states:eu-central-1:127214194449:stateMachine:stt-poc-pipeline \
  --input file://entree.json

aws stepfunctions describe-execution --execution-arn <executionArn renvoyé> --query status
```

## 8. Rejouer ou arrêter

- **Rejouer avec le même fichier** : page d'une exécution > *Start new execution* (reprend l'entrée). **Changer `execution_id`** avant de valider (section 3).
- **Arrêter** une exécution bloquée : bouton *Stop execution*. Le job MediaConvert ou Transcribe déjà lancé continue de son côté jusqu'à sa fin (et sera facturé) ; son événement de fin, lui, sera ignoré.

## 9. Si quelque chose ne va pas

| Symptôme | Cause probable et action |
|---|---|
| Échec immédiat à `ValidateInput`, `InputNotFound` | Mauvaise clé S3, faute dans le nom du fichier, ou fichier dans un autre bucket. Vérifier dans la console S3 le chemin exact |
| `InputInvalid` | Extension non reconnue, bucket différent de celui du POC, ou fichier vide ou non audio |
| Échec à `SubmitMediaConvert` avec `InvalidParameters` | `stereo_mode` autre que `downmix`/`keep`, ou `keep` combiné à `max_speaker_labels` |
| `States.Runtime` ou erreur de chemin JSON (`JsonPath ... could not be found`) | Un champ obligatoire manque dans le JSON d'entrée (`input`, `stereo_mode`, `transcribe`, `execution_id`) |
| `NoAudioStream` | Le fichier ne contient pas de piste audio (vidéo muette) |
| `InvalidParameters` à `SubmitTranscribe` | Vocabulaire personnalisé inexistant ou langue/option non prise en charge |
| Reste en `TRANSCODING` plus de 15 minutes | Voir les journaux de `stt-poc-callback` et la règle EventBridge `stt-poc-mediaconvert-job-state` (README, section « En cas de problème ») |
| Reste en `TRANSCRIBING` | Idem avec la règle `stt-poc-transcribe-job-state` ; vérifier aussi que `execution_id` est bien nouveau (section 3) |
| Exécution en échec avec un email reçu | Échec technique : lire **Error** et **Cause** de l'état en rouge, puis les journaux CloudWatch de la Lambda concernée |
| `Execution Already Exists` au démarrage | Le champ *Name* de l'exécution a déjà été utilisé : le laisser vide |
