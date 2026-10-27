{
  "TableName": "__PREFIX__-tasks",
  "AttributeDefinitions": [
    {
      "AttributeName": "execution_id",
      "AttributeType": "S"
    },
    {
      "AttributeName": "stage",
      "AttributeType": "S"
    }
  ],
  "KeySchema": [
    {
      "AttributeName": "execution_id",
      "KeyType": "HASH"
    },
    {
      "AttributeName": "stage",
      "KeyType": "RANGE"
    }
  ],
  "BillingMode": "PAY_PER_REQUEST",
  "Tags": [
    {
      "Key": "project",
      "Value": "stt-poc"
    }
  ]
}
