{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadAndDeleteTaskToken",
      "Effect": "Allow",
      "Action": [
        "dynamodb:GetItem",
        "dynamodb:DeleteItem"
      ],
      "Resource": "arn:aws:dynamodb:__REGION__:__ACCOUNT_ID__:table/__PREFIX__-tasks"
    },
    {
      "Sid": "NotifyStepFunctions",
      "Effect": "Allow",
      "Action": [
        "states:SendTaskSuccess",
        "states:SendTaskFailure"
      ],
      "Resource": "*"
    }
  ]
}
