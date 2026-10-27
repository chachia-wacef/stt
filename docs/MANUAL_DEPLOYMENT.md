# Déploiement manuel du POC (commandes AWS CLI ou console AWS)

Ce guide décrit comment déployer le POC **sans les scripts** `scripts/deploy_all.sh`, soit avec des commandes AWS CLI, soit avec la console web. Il produit exactement les mêmes ressources, avec les mêmes noms. Utile pour comprendre ce que fait chaque script, déployer pas à pas, ou travailler sans Bash.

> Les captures d'écran et libellés de la console AWS évoluent : les intitulés ci-dessous sont indicatifs. Les valeurs à saisir, elles, sont exactes.

## 0. Vue d'ensemble

### Ordre à respecter

| # | Étape | Dépend de |
|---|---|---|
| 1 | Variables et fichiers rendus (section 1) | |
| 2 | Bucket S3 et templates MediaConvert | 1 |
| 3 | Tables DynamoDB | 1 |
| 4 | Topic SNS et abonnement email | 1 |
| 5 | Rôles IAM (6) | 2, 3, 4 (les politiques citent leurs noms) |
| 6 | Layer `ffprobe` | 2 |
| 7 | File MediaConvert `Default` | 5 |
| 8 | Lambdas (4) | 3, 5, 6 |
| 9 | State machine | 4, 5, 8 |
| 10 | Règles EventBridge | 8 |
| 11 | Vérification | tout |

### Ressources créées (avec `PREFIX=stt-poc`)

| Type | Nom |
|---|---|
| Bucket S3 | `stt-poc-<compte>-<région>` |
| Tables DynamoDB | `stt-poc-executions`, `stt-poc-tasks` |
| Topic SNS | `stt-poc-alerts` |
| Rôles IAM | `stt-poc-lambda-validate-input`, `stt-poc-lambda-submit-mediaconvert`, `stt-poc-lambda-submit-transcribe`, `stt-poc-lambda-callback`, `stt-poc-states`, `stt-poc-mediaconvert` |
| Layer | `stt-poc-ffprobe` |
| Lambdas | `stt-poc-validate-input`, `stt-poc-submit-mediaconvert`, `stt-poc-submit-transcribe`, `stt-poc-callback` |
| State machine | `stt-poc-pipeline` |
| Règles EventBridge | `stt-poc-mediaconvert-job-state`, `stt-poc-transcribe-job-state` |

Ces noms sont **liés entre eux** : la state machine appelle les Lambdas par leur nom, les politiques IAM citent les tables et le bucket, la règle Transcribe filtre sur le préfixe des noms de job. Garder le même `PREFIX` partout.

## 1. Variables et fichiers rendus

Les fichiers `*.tpl` du POC contiennent des marqueurs à remplacer :

| Marqueur | Valeur |
|---|---|
| `__PREFIX__` | `stt-poc` (ou votre préfixe) |
| `__REGION__` | région, par exemple `eu-central-1` |
| `__ACCOUNT_ID__` | numéro de compte (12 chiffres) |
| `__BUCKET__` | nom du bucket |
| `__MEDIACONVERT_ROLE_ARN__` | `arn:aws:iam::<compte>:role/<PREFIX>-mediaconvert` |

### 1.1 Avec la CLI (Bash : Linux, macOS, Git Bash)

Se placer dans le dossier `poc` puis :

```bash
export PREFIX=stt-poc
export AWS_REGION=eu-central-1
export AWS_DEFAULT_REGION=$AWS_REGION
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET=$PREFIX-$ACCOUNT_ID-$AWS_REGION            # doit être unique mondialement
export MC_ROLE_ARN=arn:aws:iam::$ACCOUNT_ID:role/$PREFIX-mediaconvert
export MC_QUEUE_ARN=arn:aws:mediaconvert:$AWS_REGION:$ACCOUNT_ID:queues/Default
export TOPIC_ARN=arn:aws:sns:$AWS_REGION:$ACCOUNT_ID:$PREFIX-alerts

mkdir -p build
render() {
  sed -e "s|__PREFIX__|$PREFIX|g" -e "s|__REGION__|$AWS_REGION|g" -e "s|__ACCOUNT_ID__|$ACCOUNT_ID|g" \
      -e "s|__BUCKET__|$BUCKET|g" -e "s|__MEDIACONVERT_ROLE_ARN__|$MC_ROLE_ARN|g" "$1" > "$2"
}

render mediaconvert/job-mono.json.tpl            build/job-mono.json
render mediaconvert/job-stereo-keep.json.tpl     build/job-stereo-keep.json
render mediaconvert/job-stereo-downmix.json.tpl  build/job-stereo-downmix.json
render dynamodb/tasks.json.tpl                   build/tasks.json
render dynamodb/executions.json.tpl              build/executions.json
render iam/policy-validate-input.json.tpl        build/policy-validate-input.json
render iam/policy-submit-mediaconvert.json.tpl   build/policy-submit-mediaconvert.json
render iam/policy-submit-transcribe.json.tpl     build/policy-submit-transcribe.json
render iam/policy-callback.json.tpl              build/policy-callback.json
render iam/policy-states.json.tpl                build/policy-states.json
render iam/policy-mediaconvert-role.json.tpl     build/policy-mediaconvert-role.json
render state_machine/pipeline.asl.json.tpl       build/pipeline.asl.json
render events/transcribe-pattern.json.tpl        build/transcribe-pattern.json
cp events/mediaconvert-pattern.json              build/mediaconvert-pattern.json

grep -l "__[A-Z_]*__" build/* || echo "OK : aucun marqueur restant"
```

Les commandes des sections suivantes utilisent ces variables et ces fichiers. Sous **PowerShell**, les variables s'écrivent `$env:PREFIX = "stt-poc"` et se lisent `$env:PREFIX` ; le plus simple est d'ouvrir Git Bash.

### 1.2 Avec la console (sans CLI)

Ouvrir chaque fichier `.tpl` dans un éditeur de texte, remplacer les marqueurs du tableau ci-dessus (rechercher/remplacer), puis copier le contenu au moment où l'étape le demande. Les fichiers concernés sont indiqués à chaque étape.

## 2. Bucket S3 et templates MediaConvert

### CLI

```bash
# Région autre que us-east-1 :
aws s3api create-bucket --bucket "$BUCKET" --region "$AWS_REGION" \
  --create-bucket-configuration LocationConstraint="$AWS_REGION"
# (us-east-1 : retirer --create-bucket-configuration)

for t in job-mono job-stereo-keep job-stereo-downmix; do
  aws s3 cp build/$t.json s3://$BUCKET/templates/$t.json
done
```

### Console

1. **S3** > *Create bucket* : nom = `stt-poc-<compte>-<région>`, région = celle choisie, laisser les options par défaut (accès public bloqué, chiffrement SSE-S3). *Create bucket*.
2. Ouvrir le bucket > *Create folder* `templates`.
3. Dans `templates/` > *Upload* : les trois fichiers `job-mono.json`, `job-stereo-keep.json`, `job-stereo-downmix.json` (versions avec marqueurs remplacés, **sans** l'extension `.tpl`).

Le code des Lambdas lit exactement `templates/job-mono.json`, `templates/job-stereo-keep.json` et `templates/job-stereo-downmix.json` : respecter ces noms.

## 3. Tables DynamoDB

### CLI

```bash
aws dynamodb create-table --cli-input-json file://build/tasks.json
aws dynamodb create-table --cli-input-json file://build/executions.json
aws dynamodb wait table-exists --table-name $PREFIX-tasks
aws dynamodb wait table-exists --table-name $PREFIX-executions

aws dynamodb update-time-to-live --table-name $PREFIX-tasks \
  --time-to-live-specification "Enabled=true,AttributeName=ttl"
```

### Console

| Table | Nom | Clé de partition | Clé de tri | Capacité |
|---|---|---|---|---|
| Jetons | `stt-poc-tasks` | `execution_id` (Chaîne) | `stage` (Chaîne) | À la demande (*On-demand*) |
| Suivi | `stt-poc-executions` | `execution_id` (Chaîne) | aucune | À la demande |

Puis, pour `stt-poc-tasks` : onglet *Additional settings* > *Time to Live (TTL)* > *Turn on* > nom d'attribut `ttl`.

## 4. Topic SNS et abonnement email

### CLI

```bash
aws sns create-topic --name $PREFIX-alerts
aws sns subscribe --topic-arn "$TOPIC_ARN" --protocol email --notification-endpoint vous@exemple.com
```

### Console

**SNS** > *Topics* > *Create topic* : type *Standard*, nom `stt-poc-alerts`. Puis *Create subscription* : protocole *Email*, endpoint = votre adresse.

**Dans les deux cas : ouvrir la boîte mail et confirmer l'abonnement** (message « AWS Notification - Subscription Confirmation »). Sans confirmation, aucune alerte n'arrive.

## 5. Rôles IAM

Six rôles. Pour chacun : une **relation de confiance** (qui peut l'utiliser) et une **politique en ligne** (ce qu'il peut faire).

| Rôle | Relation de confiance | Politique en ligne (fichier rendu) | Politique gérée |
|---|---|---|---|
| `stt-poc-lambda-validate-input` | `iam/trust-lambda.json` | `build/policy-validate-input.json` | `AWSLambdaBasicExecutionRole` |
| `stt-poc-lambda-submit-mediaconvert` | `iam/trust-lambda.json` | `build/policy-submit-mediaconvert.json` | `AWSLambdaBasicExecutionRole` |
| `stt-poc-lambda-submit-transcribe` | `iam/trust-lambda.json` | `build/policy-submit-transcribe.json` | `AWSLambdaBasicExecutionRole` |
| `stt-poc-lambda-callback` | `iam/trust-lambda.json` | `build/policy-callback.json` | `AWSLambdaBasicExecutionRole` |
| `stt-poc-states` | `iam/trust-states.json` | `build/policy-states.json` | aucune |
| `stt-poc-mediaconvert` | `iam/trust-mediaconvert.json` | `build/policy-mediaconvert-role.json` | aucune |

### CLI

```bash
BASIC=arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

mkrole() { # NOM CONFIANCE POLITIQUE AVEC_LOGS(1|0)
  aws iam create-role --role-name "$1" --assume-role-policy-document "file://$2" --tags Key=project,Value=stt-poc > /dev/null
  [ "$4" = "1" ] && aws iam attach-role-policy --role-name "$1" --policy-arn "$BASIC"
  aws iam put-role-policy --role-name "$1" --policy-name inline --policy-document "file://$3"
}

mkrole $PREFIX-lambda-validate-input      iam/trust-lambda.json       build/policy-validate-input.json      1
mkrole $PREFIX-lambda-submit-mediaconvert iam/trust-lambda.json       build/policy-submit-mediaconvert.json 1
mkrole $PREFIX-lambda-submit-transcribe   iam/trust-lambda.json       build/policy-submit-transcribe.json   1
mkrole $PREFIX-lambda-callback            iam/trust-lambda.json       build/policy-callback.json            1
mkrole $PREFIX-states                      iam/trust-states.json       build/policy-states.json              0
mkrole $PREFIX-mediaconvert                iam/trust-mediaconvert.json build/policy-mediaconvert-role.json   0
```

### Console (à répéter pour chaque rôle)

1. **IAM** > *Roles* > *Create role*.
2. *Trusted entity type* : **Custom trust policy**. Coller le contenu du fichier de confiance du tableau (`iam/trust-lambda.json`, `trust-states.json` ou `trust-mediaconvert.json`). *Next*.
3. Pour les quatre rôles Lambda : cocher la politique `AWSLambdaBasicExecutionRole`. Pour les deux autres : aucune. *Next*.
4. *Role name* : le nom du tableau. *Create role*.
5. Ouvrir le rôle > *Permissions* > *Add permissions* > *Create inline policy* > onglet **JSON** > coller le contenu du fichier rendu du tableau > nom `inline` > *Create policy*.

Un rôle tout juste créé peut mettre quelques secondes à être utilisable : en cas d'erreur « role cannot be assumed » plus loin, patienter et réessayer.

## 6. Layer `ffprobe`

La Lambda de transcodage appelle `/opt/bin/ffprobe` pour savoir si l'audio est mono ou stéréo. La layer contient ce binaire (le script produit un zip avec les droits d'exécution, indispensables).

```bash
python scripts/build_ffprobe_layer.py build/ffprobe-layer.zip          # télécharge environ 40 Mo, vérifie le MD5
```

Option : `--binary /chemin/ffprobe` pour utiliser votre propre binaire statique Linux. Vérifier la licence du binaire téléchargé avec votre équipe avant tout usage au-delà du POC.

### CLI

```bash
aws s3 cp build/ffprobe-layer.zip s3://$BUCKET/layers/ffprobe-layer.zip
export LAYER_ARN=$(aws lambda publish-layer-version --layer-name $PREFIX-ffprobe \
  --content S3Bucket=$BUCKET,S3Key=layers/ffprobe-layer.zip \
  --compatible-runtimes python3.12 --compatible-architectures x86_64 \
  --query LayerVersionArn --output text)
echo "$LAYER_ARN"
```

### Console

1. Envoyer `build/ffprobe-layer.zip` dans le bucket sous `layers/ffprobe-layer.zip` (S3 > *Upload*).
2. **Lambda** > *Layers* > *Create layer* : nom `stt-poc-ffprobe`, *Upload a file from Amazon S3* avec l'URL `https://<bucket>.s3.<région>.amazonaws.com/layers/ffprobe-layer.zip`, architecture **x86_64**, runtime **Python 3.12**.
3. Noter l'ARN de la version créée (utilisé à l'étape 8).

## 7. File MediaConvert `Default`

MediaConvert crée sa file `Default` à la première utilisation du service dans la région. Pour la matérialiser :

```bash
aws mediaconvert list-queues --query "Queues[].Name" --output text
```

ou ouvrir une fois la console **MediaConvert** dans la région. Le résultat doit contenir `Default`.

## 8. Lambdas

### 8.1 Paramètres de chaque fonction

Toutes : runtime **Python 3.12**, architecture **x86_64**, handler `lambda_function.lambda_handler`.

| Fonction | Rôle | Timeout | Mémoire | Layer | Code source |
|---|---|---|---|---|---|
| `stt-poc-validate-input` | `stt-poc-lambda-validate-input` | 30 s | 128 Mo | non | `lambdas/validate_input/lambda_function.py` |
| `stt-poc-submit-mediaconvert` | `stt-poc-lambda-submit-mediaconvert` | 90 s | 512 Mo | `stt-poc-ffprobe` | `lambdas/submit_mediaconvert/lambda_function.py` |
| `stt-poc-submit-transcribe` | `stt-poc-lambda-submit-transcribe` | 30 s | 128 Mo | non | `lambdas/submit_transcribe/lambda_function.py` |
| `stt-poc-callback` | `stt-poc-lambda-callback` | 30 s | 128 Mo | non | `lambdas/callback/lambda_function.py` |

### 8.2 Variables d'environnement

| Fonction | Variable | Valeur |
|---|---|---|
| `validate-input` | `ALLOWED_BUCKETS` | `<bucket>` |
| `submit-mediaconvert` | `TEMPLATES_BUCKET` | `<bucket>` |
| | `OUTPUT_BUCKET` | `<bucket>` |
| | `TASKS_TABLE` | `stt-poc-tasks` |
| | `EXECUTIONS_TABLE` | `stt-poc-executions` |
| | `MEDIACONVERT_ROLE_ARN` | `arn:aws:iam::<compte>:role/stt-poc-mediaconvert` |
| | `MEDIACONVERT_QUEUE_ARN` | `arn:aws:mediaconvert:<région>:<compte>:queues/Default` |
| `submit-transcribe` | `OUTPUT_BUCKET` | `<bucket>` |
| | `ALLOWED_BUCKETS` | `<bucket>` |
| | `TASKS_TABLE` | `stt-poc-tasks` |
| | `EXECUTIONS_TABLE` | `stt-poc-executions` |
| | `TRANSCRIBE_JOB_PREFIX` | `stt-poc-` (avec le tiret final) |
| `callback` | `TASKS_TABLE` | `stt-poc-tasks` |
| | `TRANSCRIBE_JOB_PREFIX` | `stt-poc-` (avec le tiret final) |

`TRANSCRIBE_JOB_PREFIX` doit être identique dans `submit-transcribe`, `callback` et le motif de la règle EventBridge Transcribe (étape 10) : c'est ainsi que l'`execution_id` est retrouvé à partir du nom du job.

### 8.3 CLI

Chaque Lambda est un seul fichier : l'archive contient `lambda_function.py` **à la racine**.

```bash
for d in validate_input submit_mediaconvert submit_transcribe callback; do
  python scripts/make_zip.py build/$d.zip lambdas/$d/lambda_function.py=lambda_function.py
done

R=arn:aws:iam::$ACCOUNT_ID:role
H=lambda_function.lambda_handler

aws lambda create-function --function-name $PREFIX-validate-input --runtime python3.12 --handler $H \
  --role $R/$PREFIX-lambda-validate-input --timeout 30 --memory-size 128 \
  --zip-file fileb://build/validate_input.zip \
  --environment "Variables={ALLOWED_BUCKETS=$BUCKET}"

aws lambda create-function --function-name $PREFIX-submit-mediaconvert --runtime python3.12 --handler $H \
  --role $R/$PREFIX-lambda-submit-mediaconvert --timeout 90 --memory-size 512 \
  --zip-file fileb://build/submit_mediaconvert.zip --layers "$LAYER_ARN" \
  --environment "Variables={TEMPLATES_BUCKET=$BUCKET,OUTPUT_BUCKET=$BUCKET,TASKS_TABLE=$PREFIX-tasks,EXECUTIONS_TABLE=$PREFIX-executions,MEDIACONVERT_ROLE_ARN=$MC_ROLE_ARN,MEDIACONVERT_QUEUE_ARN=$MC_QUEUE_ARN}"

aws lambda create-function --function-name $PREFIX-submit-transcribe --runtime python3.12 --handler $H \
  --role $R/$PREFIX-lambda-submit-transcribe --timeout 30 --memory-size 128 \
  --zip-file fileb://build/submit_transcribe.zip \
  --environment "Variables={OUTPUT_BUCKET=$BUCKET,ALLOWED_BUCKETS=$BUCKET,TASKS_TABLE=$PREFIX-tasks,EXECUTIONS_TABLE=$PREFIX-executions,TRANSCRIBE_JOB_PREFIX=$PREFIX-}"

aws lambda create-function --function-name $PREFIX-callback --runtime python3.12 --handler $H \
  --role $R/$PREFIX-lambda-callback --timeout 30 --memory-size 128 \
  --zip-file fileb://build/callback.zip \
  --environment "Variables={TASKS_TABLE=$PREFIX-tasks,TRANSCRIBE_JOB_PREFIX=$PREFIX-}"
```

Mise à jour du code seul : `aws lambda update-function-code --function-name <nom> --zip-file fileb://build/<fichier>.zip`.

### 8.4 Console (à répéter pour chaque fonction)

1. **Lambda** > *Create function* > *Author from scratch* : nom, runtime *Python 3.12*, architecture *x86_64*.
2. *Change default execution role* > *Use an existing role* > le rôle du tableau 8.1. *Create function*.
3. Onglet *Code* : *Upload from* > *.zip file* (archive contenant `lambda_function.py` à la racine). Pour une archive d'un seul fichier, il est aussi possible de coller le contenu du fichier dans l'éditeur de code puis *Deploy*.
4. *Configuration* > *General configuration* > *Edit* : mémoire et timeout du tableau 8.1.
5. *Configuration* > *Environment variables* > *Edit* : les variables du tableau 8.2.
6. Pour `submit-mediaconvert` seulement : onglet *Code*, en bas > *Layers* > *Add a layer* > *Custom layers* > `stt-poc-ffprobe` (version 1).
7. Le handler par défaut (`lambda_function.lambda_handler`) est correct.

### 8.5 Conservation des journaux (facultatif)

CloudWatch > *Log groups* > `/aws/lambda/<fonction>` > *Actions* > *Edit retention setting* : 14 jours. Le groupe apparaît après la première invocation (ou le créer à la main). CLI : `aws logs put-retention-policy --log-group-name /aws/lambda/<fonction> --retention-in-days 14` (sous Git Bash, préfixer par `MSYS_NO_PATHCONV=1`).

### 8.6 Contrôle rapide

```bash
aws lambda invoke --function-name $PREFIX-validate-input --cli-binary-format raw-in-base64-out \
  --payload "{\"execution_id\":\"t1\",\"input\":\"s3://$BUCKET/input/inexistant.mp3\"}" out.json; cat out.json
```

Résultat attendu : une erreur `InputNotFound` (la fonction répond « FunctionError »). Console : onglet *Test* avec l'événement `{"execution_id":"t1","input":"s3://<bucket>/input/inexistant.mp3"}`.

## 9. State machine

La définition rendue est `build/pipeline.asl.json` (le modèle est `state_machine/pipeline.asl.json.tpl`).

### CLI

```bash
LOG_GROUP=/aws/vendedlogs/states/$PREFIX-pipeline
MSYS_NO_PATHCONV=1 aws logs create-log-group --log-group-name $LOG_GROUP

MSYS_NO_PATHCONV=1 aws stepfunctions create-state-machine --name $PREFIX-pipeline --type STANDARD \
  --definition file://build/pipeline.asl.json \
  --role-arn arn:aws:iam::$ACCOUNT_ID:role/$PREFIX-states \
  --logging-configuration "{\"level\":\"ERROR\",\"includeExecutionData\":false,\"destinations\":[{\"cloudWatchLogsLogGroup\":{\"logGroupArn\":\"arn:aws:logs:$AWS_REGION:$ACCOUNT_ID:log-group:$LOG_GROUP:*\"}}]}"

export SM_ARN=arn:aws:states:$AWS_REGION:$ACCOUNT_ID:stateMachine:$PREFIX-pipeline
```

Mise à jour : `aws stepfunctions update-state-machine --state-machine-arn $SM_ARN --definition file://build/pipeline.asl.json`.

### Console

1. **Step Functions** > *State machines* > *Create state machine* > modèle *Blank*.
2. Mode **Code** : coller le contenu de `build/pipeline.asl.json`. *Next* (ou *Config*).
3. Nom : `stt-poc-pipeline`. Type : **Standard**.
4. *Permissions* : **Choose an existing role** > `stt-poc-states` (ne pas laisser la console en créer un).
5. *Logging* : niveau **ERROR** (ou ALL pour la démonstration), *Include execution data* désactivé, groupe de logs : créer ou choisir `/aws/vendedlogs/states/stt-poc-pipeline`.
6. *Create state machine*.

La console valide la syntaxe de la définition (chemins JSON, fonctions intrinsèques) : les erreurs éventuelles s'affichent à cet endroit. Les noms des Lambdas, des tables et du topic référencés dans la définition doivent exister avec exactement ces noms.

## 10. Règles EventBridge

Deux règles sur le bus d'événements **par défaut**, avec la Lambda `stt-poc-callback` comme cible.

| Règle | Motif d'événement (fichier rendu) |
|---|---|
| `stt-poc-mediaconvert-job-state` | `build/mediaconvert-pattern.json` |
| `stt-poc-transcribe-job-state` | `build/transcribe-pattern.json` |

### CLI

```bash
CALLBACK_ARN=arn:aws:lambda:$AWS_REGION:$ACCOUNT_ID:function:$PREFIX-callback

for r in mediaconvert transcribe; do
  aws events put-rule --name $PREFIX-$r-job-state --event-pattern file://build/$r-pattern.json
  aws events put-targets --rule $PREFIX-$r-job-state --targets "Id=callback,Arn=$CALLBACK_ARN"
  aws lambda add-permission --function-name $PREFIX-callback --statement-id events-$r \
    --action lambda:InvokeFunction --principal events.amazonaws.com \
    --source-arn arn:aws:events:$AWS_REGION:$ACCOUNT_ID:rule/$PREFIX-$r-job-state
done
```

### Console (à répéter pour chaque règle)

1. **Amazon EventBridge** > *Rules* > *Create rule*.
2. Nom du tableau ci-dessus, bus *default*, type **Rule with an event pattern**. *Next*.
3. *Event source* : *AWS events or EventBridge partner events*. *Creation method* : **Custom pattern (JSON editor)** et coller le contenu du fichier rendu. *Next*.
4. *Target types* : **AWS service** > *Select a target* : **Lambda function** > `stt-poc-callback`. *Next*, puis *Create rule*.

La console ajoute automatiquement l'autorisation d'appeler la Lambda (équivalent de `add-permission`).

## 11. Vérification et premier essai

### 11.1 Lancer un traitement

```bash
# 1. Envoyer un court fichier de parole
aws s3 cp mon-fichier.mp3 s3://$BUCKET/input/demo/mon-fichier.mp3

# 2. Démarrer l'exécution
ID=$(python -c "import uuid; print(uuid.uuid4())")
cat > build/input.json <<EOF
{
  "execution_id": "$ID",
  "owner": "poc",
  "input": "s3://$BUCKET/input/demo/mon-fichier.mp3",
  "stereo_mode": "downmix",
  "transcribe": { "language_code": "fr-FR" }
}
EOF
aws stepfunctions start-execution --state-machine-arn $SM_ARN --name $ID --input file://build/input.json
```

Console : *Step Functions* > la state machine > *Start execution* > coller le même JSON (avec un `execution_id` quelconque, par exemple `demo-1`).

Options de `transcribe` : `language_code` **ou** `identify_language` (avec `language_options` facultatif), `max_speaker_labels` (2 à 30, incompatible avec `stereo_mode: keep`), `vocabulary_name`. `stereo_mode` : `downmix` ou `keep`.

### 11.2 Suivre l'avancement

```bash
aws stepfunctions describe-execution --execution-arn arn:aws:states:$AWS_REGION:$ACCOUNT_ID:execution:$PREFIX-pipeline:$ID --query status
aws dynamodb get-item --table-name $PREFIX-executions --key "{\"execution_id\":{\"S\":\"$ID\"}}"
aws s3 ls s3://$BUCKET/output/$ID/
aws s3 ls s3://$BUCKET/transcripts/$ID/
```

Statuts métier successifs dans la table : `VALIDATING`, `TRANSCODING`, `TRANSCRIBING`, `DONE`. En console : le graphe de l'exécution Step Functions se colore étape par étape.

### 11.3 Lire la transcription

```bash
aws s3 cp s3://$BUCKET/transcripts/$ID/transcript.json - | python scripts/show_transcript.py
```

### 11.4 Tester les échecs

| Test | Comment | Attendu |
|---|---|---|
| Fichier non audio | `echo "pas de l'audio" > faux.mp3`, l'envoyer puis démarrer une exécution dessus | Statut `FAILED`, code `InputInvalid`, exécution « réussie », **pas d'email** |
| Fichier absent | Entrée pointant vers une clé inexistante | `InputNotFound` dès la première étape, pas d'email |
| Panne technique | Mettre `NOT_FOUND_RETRIES=oops` dans les variables de `validate-input`, démarrer une exécution, puis retirer la variable | Exécution en échec, statut `FAILED` générique, **email** reçu |

## 12. Si une étape échoue

| Symptôme | Cause probable |
|---|---|
| `AccessDenied` à la création d'une ressource | Droits de la personne qui déploie |
| `The role defined for the function cannot be assumed by Lambda` | Rôle créé il y a quelques secondes, ou relation de confiance incorrecte : patienter et réessayer, vérifier `trust-lambda.json` |
| Bucket « already exists » | Nom non unique : changer `BUCKET` |
| Erreur à la création de la state machine mentionnant un état ou un chemin | Marqueur `__...__` non remplacé dans la définition, ou erreur de copier-coller |
| Exécution bloquée en `TRANSCODING` ou `TRANSCRIBING` | Règle EventBridge absente, motif incorrect, Lambda `callback` sans autorisation d'invocation, ou noms de préfixe différents : voir les journaux de `stt-poc-callback` et la console MediaConvert / Transcribe. L'exécution expire seule (15 min / 30 min) |
| `ffprobe: Permission denied` ou fichier introuvable | Layer absente de `stt-poc-submit-mediaconvert`, ou archive construite sans les droits d'exécution (utiliser `scripts/build_ffprobe_layer.py`) |
| Pas d'email d'alerte | Abonnement SNS non confirmé, ou topic différent de `stt-poc-alerts` dans la définition |
| `Invalid ... ` dans le job MediaConvert | Voir le détail du job dans la console MediaConvert et les journaux de `submit-mediaconvert` |

## 13. Suppression manuelle

Dans cet ordre (inverse de la création) :

```bash
for r in mediaconvert transcribe; do
  aws events remove-targets --rule $PREFIX-$r-job-state --ids callback
  aws events delete-rule --name $PREFIX-$r-job-state
done
aws stepfunctions delete-state-machine --state-machine-arn $SM_ARN
for f in validate-input submit-mediaconvert submit-transcribe callback; do aws lambda delete-function --function-name $PREFIX-$f; done
for v in $(aws lambda list-layer-versions --layer-name $PREFIX-ffprobe --query "LayerVersions[].Version" --output text); do
  aws lambda delete-layer-version --layer-name $PREFIX-ffprobe --version-number $v; done
aws dynamodb delete-table --table-name $PREFIX-tasks
aws dynamodb delete-table --table-name $PREFIX-executions
aws sns delete-topic --topic-arn $TOPIC_ARN
for role in lambda-validate-input lambda-submit-mediaconvert lambda-submit-transcribe lambda-callback states mediaconvert; do
  aws iam detach-role-policy --role-name $PREFIX-$role --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null
  aws iam delete-role-policy --role-name $PREFIX-$role --policy-name inline
  aws iam delete-role --role-name $PREFIX-$role
done
aws s3 rb s3://$BUCKET --force
```

Supprimer aussi les groupes de logs (`/aws/lambda/stt-poc-*` et `/aws/vendedlogs/states/stt-poc-pipeline`) dans CloudWatch. Console : supprimer chaque ressource depuis son service, dans le même ordre.

## 14. Correspondance avec les scripts

| Étape de ce guide | Script équivalent |
|---|---|
| 1 (variables, rendu) | fonction `render` de `scripts/common.sh` |
| 2, 3, 4 | `scripts/01_storage.sh` |
| 5, 7 | `scripts/02_iam.sh` |
| 6 | `scripts/03_layer.sh` |
| 8 | `scripts/04_lambdas.sh` |
| 9 | `scripts/05_state_machine.sh` |
| 10 | `scripts/06_events.sh` |
| 11 | `scripts/run_demo.sh`, `scripts/demo_failure.sh` |
| 13 | `scripts/destroy.sh` |
