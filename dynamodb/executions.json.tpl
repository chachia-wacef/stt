{
  "TableName": "__PREFIX__-executions",
  "AttributeDefinitions": [
    {
      "AttributeName": "execution_id",
      "AttributeType": "S"
    }
  ],
  "KeySchema": [
    {
      "AttributeName": "execution_id",
      "KeyType": "HASH"
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
