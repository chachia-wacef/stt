{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "InvokePipelineLambdas",
      "Effect": "Allow",
      "Action": "lambda:InvokeFunction",
      "Resource": [
        "arn:aws:lambda:__REGION__:__ACCOUNT_ID__:function:__PREFIX__-validate-input",
        "arn:aws:lambda:__REGION__:__ACCOUNT_ID__:function:__PREFIX__-validate-input:*",
        "arn:aws:lambda:__REGION__:__ACCOUNT_ID__:function:__PREFIX__-submit-mediaconvert",
        "arn:aws:lambda:__REGION__:__ACCOUNT_ID__:function:__PREFIX__-submit-mediaconvert:*",
        "arn:aws:lambda:__REGION__:__ACCOUNT_ID__:function:__PREFIX__-submit-transcribe",
        "arn:aws:lambda:__REGION__:__ACCOUNT_ID__:function:__PREFIX__-submit-transcribe:*"
      ]
    },
    {
      "Sid": "UpdateExecutionStatus",
      "Effect": "Allow",
      "Action": "dynamodb:UpdateItem",
      "Resource": "arn:aws:dynamodb:__REGION__:__ACCOUNT_ID__:table/__PREFIX__-executions"
    },
    {
      "Sid": "PublishAlerts",
      "Effect": "Allow",
      "Action": "sns:Publish",
      "Resource": "arn:aws:sns:__REGION__:__ACCOUNT_ID__:__PREFIX__-alerts"
    },
    {
      "Sid": "StateMachineLogging",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogDelivery",
        "logs:GetLogDelivery",
        "logs:UpdateLogDelivery",
        "logs:DeleteLogDelivery",
        "logs:ListLogDeliveries",
        "logs:PutResourcePolicy",
        "logs:DescribeResourcePolicies",
        "logs:DescribeLogGroups"
      ],
      "Resource": "*"
    }
  ]
}
