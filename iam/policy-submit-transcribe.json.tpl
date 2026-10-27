{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "StartTranscriptionJob",
      "Effect": "Allow",
      "Action": "transcribe:StartTranscriptionJob",
      "Resource": "*"
    },
    {
      "Sid": "ReadMediaForTranscribe",
      "Effect": "Allow",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::__BUCKET__/output/*"
    },
    {
      "Sid": "WriteTranscriptsForTranscribe",
      "Effect": "Allow",
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::__BUCKET__/transcripts/*"
    },
    {
      "Sid": "StoreAndCleanTaskToken",
      "Effect": "Allow",
      "Action": [
        "dynamodb:PutItem",
        "dynamodb:DeleteItem"
      ],
      "Resource": "arn:aws:dynamodb:__REGION__:__ACCOUNT_ID__:table/__PREFIX__-tasks"
    },
    {
      "Sid": "TrackTranscribeJob",
      "Effect": "Allow",
      "Action": "dynamodb:UpdateItem",
      "Resource": "arn:aws:dynamodb:__REGION__:__ACCOUNT_ID__:table/__PREFIX__-executions"
    },
    {
      "Sid": "ReportBusinessFailure",
      "Effect": "Allow",
      "Action": "states:SendTaskFailure",
      "Resource": "*"
    }
  ]
}
