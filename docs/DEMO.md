# Guide de démonstration

Déroulé conseillé pour présenter le POC à l'équipe (20 à 30 minutes). Prérequis : le POC est déployé (`scripts/deploy_all.sh`), l'abonnement email SNS est confirmé.

## 0. Préparation (la veille ou 10 minutes avant)

| À préparer | Détail |
|---|---|
| Fichiers de test | Un mp3 **mono** de parole, 30 à 60 s (le plus simple). Si possible : un enregistrement **stéréo** dont une voix par canal (pour `--stereo keep`), un fichier avec **deux locuteurs** (pour la diarisation), une courte vidéo mp4 avec son |
| Un faux fichier | `echo "ceci n'est pas de l'audio" > faux.mp3` |
| Fenêtres ouvertes | Console Step Functions (state machine du POC), table DynamoDB `executions`, bucket S3, une fenêtre de terminal à la racine de `poc/`, la boîte mail |
| Essai à blanc | Lancer une fois `scripts/run_demo.sh mono.mp3` avant la présentation : les démarrages à froid et la première exécution sont plus lents |

Astuce : les jobs MediaConvert et Transcribe prennent chacun un moment ; pendant l'attente, expliquer l'architecture.

## 1. Présenter l'architecture (3 à 5 minutes)

Montrer le schéma du [README](../README.md) et dérouler :

1. Un fichier arrive dans S3, la **state machine** démarre.
2. **Validation** du fichier.
3. **Transcodage** avec MediaConvert : un audio FLAC sans perte (pour la précision) et un MP4 de lecture. La Lambda détecte d'abord mono ou stéréo.
4. La state machine **attend** le job sans consommer de calcul : **EventBridge** la réveille à la fin (via une petite Lambda).
5. **Transcription** avec Transcribe, même principe d'attente.
6. Résultat dans DynamoDB et S3 ; en cas d'incident technique, **email**.

Message clé : tout est à l'usage, rien ne tourne en attendant un fichier.

## 2. Scénario nominal (5 minutes)

```bash
bash scripts/run_demo.sh mono.mp3 --lang fr-FR
```

À montrer pendant que ça tourne :

- Le **graphe Step Functions** (lien affiché par le script) qui se colore étape par étape ; cliquer sur une étape pour voir entrée et sortie.
- La ligne dans DynamoDB `executions` dont le **statut change** : `VALIDATING` > `TRANSCODING` > `TRANSCRIBING` > `DONE`.
- La table `tasks` : la ligne du jeton apparaît pendant l'attente d'un job puis disparaît.
- La console **MediaConvert** (job en cours) puis **Transcribe**.

À la fin, montrer :

- Les fichiers dans S3 : `output/<id>/` (FLAC et MP4) et `transcripts/<id>/transcript.json`.
- La transcription affichée par le script.
- Lire le MP4 (option `--download dossier` pour le récupérer).

## 3. Variantes (facultatif, 5 minutes)

| Scénario | Commande | À montrer |
|---|---|---|
| Stéréo fusionnée | `bash scripts/run_demo.sh stereo.wav` | Le FLAC produit est mono (template `downmix`) |
| Stéréo conservée | `bash scripts/run_demo.sh stereo.wav --stereo keep` | Transcription séparée par canal (`[ch_0]`, `[ch_1]`) |
| Deux locuteurs | `bash scripts/run_demo.sh dialogue.mp3 --speakers 2` | Transcription par locuteur (`[spk_0]`, `[spk_1]`) |
| Vidéo | `bash scripts/run_demo.sh video.mp4` | Seule la piste audio est exploitée |
| Langue automatique | `bash scripts/run_demo.sh fichier.mp3 --lang auto` | Détection de la langue |

## 4. Échec lié au fichier : pas d'alerte (3 minutes)

```bash
bash scripts/run_demo.sh faux.mp3
```

Le fichier existe mais n'est pas un média lisible. Résultat :

- Statut métier `FAILED` avec le code `InputInvalid` et un message clair, affichés par le script.
- Dans Step Functions, l'exécution est **réussie** (état vert) : l'incident n'est pas technique.
- **Aucun email** : une erreur d'utilisateur ne doit pas alerter l'équipe.

Variante, un fichier absent : démarrer l'exécution depuis la console Step Functions avec

```json
{
  "execution_id": "demo-absent-1",
  "owner": "poc",
  "input": "s3://<votre-bucket>/input/demo/n-existe-pas.mp3",
  "stereo_mode": "downmix",
  "transcribe": { "language_code": "fr-FR" }
}
```

Résultat : `InputNotFound`, détecté dès la première étape.

## 5. Échec technique : alerte par email (3 minutes)

```bash
bash scripts/demo_failure.sh break      # casse volontairement la Lambda de validation
bash scripts/run_demo.sh mono.mp3       # l'exécution échoue tout de suite
bash scripts/demo_failure.sh fix        # rétablit la configuration
```

Résultat :

- L'exécution est en **échec** (état rouge) dès la validation.
- Le statut métier est `FAILED` avec un message **générique** : l'utilisateur ne voit pas le détail interne.
- Un **email** arrive avec l'identifiant d'exécution, le fichier, l'erreur, la cause et un lien direct vers l'exécution.

Penser à lancer `demo_failure.sh fix` ensuite.

## 6. Logs (1 à 2 minutes)

Dans CloudWatch Logs, ouvrir `/aws/lambda/<PREFIX>-submit-mediaconvert` : des lignes JSON avec `execution_id`, le template choisi, l'identifiant de job. Montrer aussi les logs de la state machine.

## 7. Ce qui existe au-delà du POC (2 minutes)

Pour situer la suite : API authentifiée (Cognito) et envoi de fichiers par URL présignée, notifications en temps réel du statut (WebSocket), alarmes et tableau de bord, files d'attente d'échec, puis **transcription en temps réel** (flux audio en direct). Le POC en montre le cœur, le traitement de fichiers.

## Questions fréquentes

| Question | Réponse courte |
|---|---|
| Pourquoi FLAC et pas MP3 pour Transcribe ? | Pour ne pas dégrader l'audio avant la reconnaissance : la précision est la priorité, la taille ne compte pas |
| Pourquoi deux sorties ? | Le FLAC sert à la transcription, le MP4 à la lecture dans une application |
| Pourquoi une Lambda de rappel ? | EventBridge ne peut pas réveiller Step Functions directement ; la Lambda retrouve le jeton d'attente et le fait |
| Que se passe-t-il si un événement est perdu ? | L'étape expire au délai maximal et l'exécution échoue avec une alerte (en production : file d'attente d'échec et alarme) |
| Mono ou stéréo ? | Détecté automatiquement ; pour la stéréo, on choisit entre fusion (`downmix`) et conservation des canaux (`keep`) |
| Quel est le coût ? | À l'usage : minutes de transcodage et de transcription. Rien ne coûte à l'arrêt |
| Quelles limites ? | Transcribe : 4 h et 2 Go par fichier audio envoyé, 2 canaux au maximum pour l'identification de canaux (à vérifier dans la documentation AWS) |
