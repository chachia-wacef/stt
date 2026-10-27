{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadInputAndTemplates",
      "Effect": "Allow",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::__BUCKET__/*"
    },
    {
      "Sid": "SubmitMediaConvertJob",
      "Effect": "Allow",
      "Action": "mediaconvert:CreateJob",
      "Resource": "*"
    },
    {
      "Sid": "PassRoleToMediaConvert",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::__ACCOUNT_ID__:role/__PREFIX__-mediaconvert",
      "Condition": {
        "StringEquals": {
          "iam:PassedToService": "mediaconvert.amazonaws.com"
        }
      }
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
      "Sid": "TrackMediaConvertJob",
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
