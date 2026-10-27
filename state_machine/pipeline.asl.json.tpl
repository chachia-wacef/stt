{
  "Comment": "STT POC : validation, MediaConvert (FLAC + MP4), Transcribe.",
  "StartAt": "SetStatusValidating",
  "TimeoutSeconds": 3600,
  "States": {
    "SetStatusValidating": {
      "Type": "Task",
      "Resource": "arn:aws:states:::dynamodb:updateItem",
      "Parameters": {
        "TableName": "__PREFIX__-executions",
        "Key": { "execution_id": { "S.$": "$.execution_id" } },
        "UpdateExpression": "SET #s = :s, updated_at = :u",
        "ExpressionAttributeNames": { "#s": "status" },
        "ExpressionAttributeValues": {
          ":s": { "S": "VALIDATING" },
          ":u": { "S.$": "$$.State.EnteredTime" }
        }
      },
      "ResultPath": null,
      "Retry": [{ "ErrorEquals": ["States.TaskFailed"], "IntervalSeconds": 2, "MaxAttempts": 3, "BackoffRate": 2 }],
      "Catch": [{ "ErrorEquals": ["States.ALL"], "ResultPath": "$.error", "Next": "MarkFailedTechnical" }],
      "Next": "ValidateInput"
    },

    "ValidateInput": {
      "Type": "Task",
      "Resource": "arn:aws:states:::lambda:invoke",
      "Parameters": {
        "FunctionName": "__PREFIX__-validate-input",
        "Payload": {
          "execution_id.$": "$.execution_id",
          "input.$": "$.input"
        }
      },
      "ResultSelector": {
        "bucket.$": "$.Payload.bucket",
        "key.$": "$.Payload.key",
        "input.$": "$.Payload.input",
        "extension.$": "$.Payload.extension",
        "size_bytes.$": "$.Payload.size_bytes"
      },
      "ResultPath": "$.validation",
      "Retry": [
        {
          "ErrorEquals": ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException", "Lambda.TooManyRequestsException", "ClientError"],
          "IntervalSeconds": 2,
          "MaxAttempts": 3,
          "BackoffRate": 2
        }
      ],
      "Catch": [
        { "ErrorEquals": ["InputNotFound", "InputInvalid"], "ResultPath": "$.error", "Next": "ParseLambdaError" },
        { "ErrorEquals": ["States.ALL"], "ResultPath": "$.error", "Next": "MarkFailedTechnical" }
      ],
      "Next": "SetStatusTranscoding"
    },

    "SetStatusTranscoding": {
      "Type": "Task",
      "Resource": "arn:aws:states:::dynamodb:updateItem",
      "Parameters": {
        "TableName": "__PREFIX__-executions",
        "Key": { "execution_id": { "S.$": "$.execution_id" } },
        "UpdateExpression": "SET #s = :s, updated_at = :u",
        "ExpressionAttributeNames": { "#s": "status" },
        "ExpressionAttributeValues": {
          ":s": { "S": "TRANSCODING" },
          ":u": { "S.$": "$$.State.EnteredTime" }
        }
      },
      "ResultPath": null,
      "Retry": [{ "ErrorEquals": ["States.TaskFailed"], "IntervalSeconds": 2, "MaxAttempts": 3, "BackoffRate": 2 }],
      "Catch": [{ "ErrorEquals": ["States.ALL"], "ResultPath": "$.error", "Next": "MarkFailedTechnical" }],
      "Next": "SubmitMediaConvert"
    },

    "SubmitMediaConvert": {
      "Type": "Task",
      "Resource": "arn:aws:states:::lambda:invoke.waitForTaskToken",
      "Parameters": {
        "FunctionName": "__PREFIX__-submit-mediaconvert",
        "Payload": {
          "execution_id.$": "$.execution_id",
          "task_token.$": "$$.Task.Token",
          "bucket.$": "$.validation.bucket",
          "key.$": "$.validation.key",
          "stereo_mode.$": "$.stereo_mode",
          "transcribe.$": "$.transcribe"
        }
      },
      "TimeoutSeconds": 900,
      "ResultPath": "$.mediaconvert",
      "Retry": [
        {
          "ErrorEquals": ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException", "Lambda.TooManyRequestsException"],
          "IntervalSeconds": 2,
          "MaxAttempts": 3,
          "BackoffRate": 2
        }
      ],
      "Catch": [
        {
          "ErrorEquals": ["InvalidParameters", "InputInvalid", "NoAudioStream", "UnsupportedChannels"],
          "ResultPath": "$.error",
          "Next": "ShapePlainFailure"
        },
        { "ErrorEquals": ["States.ALL"], "ResultPath": "$.error", "Next": "MarkFailedTechnical" }
      ],
      "Next": "SetStatusTranscribing"
    },

    "SetStatusTranscribing": {
      "Type": "Task",
      "Resource": "arn:aws:states:::dynamodb:updateItem",
      "Parameters": {
        "TableName": "__PREFIX__-executions",
        "Key": { "execution_id": { "S.$": "$.execution_id" } },
        "UpdateExpression": "SET #s = :s, updated_at = :u",
        "ExpressionAttributeNames": { "#s": "status" },
        "ExpressionAttributeValues": {
          ":s": { "S": "TRANSCRIBING" },
          ":u": { "S.$": "$$.State.EnteredTime" }
        }
      },
      "ResultPath": null,
      "Retry": [{ "ErrorEquals": ["States.TaskFailed"], "IntervalSeconds": 2, "MaxAttempts": 3, "BackoffRate": 2 }],
      "Catch": [{ "ErrorEquals": ["States.ALL"], "ResultPath": "$.error", "Next": "MarkFailedTechnical" }],
      "Next": "SubmitTranscribe"
    },

    "SubmitTranscribe": {
      "Type": "Task",
      "Resource": "arn:aws:states:::lambda:invoke.waitForTaskToken",
      "Parameters": {
        "FunctionName": "__PREFIX__-submit-transcribe",
        "Payload": {
          "execution_id.$": "$.execution_id",
          "task_token.$": "$$.Task.Token",
          "flac.$": "$.mediaconvert.flac",
          "template.$": "$.mediaconvert.template",
          "transcribe.$": "$.transcribe"
        }
      },
      "TimeoutSeconds": 1800,
      "ResultPath": "$.transcription",
      "Retry": [
        {
          "ErrorEquals": ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException", "Lambda.TooManyRequestsException"],
          "IntervalSeconds": 2,
          "MaxAttempts": 3,
          "BackoffRate": 2
        }
      ],
      "Catch": [
        {
          "ErrorEquals": ["InvalidParameters", "InputInvalid"],
          "ResultPath": "$.error",
          "Next": "ShapePlainFailure"
        },
        { "ErrorEquals": ["States.ALL"], "ResultPath": "$.error", "Next": "MarkFailedTechnical" }
      ],
      "Next": "Finalize"
    },

    "Finalize": {
      "Type": "Task",
      "Resource": "arn:aws:states:::dynamodb:updateItem",
      "Parameters": {
        "TableName": "__PREFIX__-executions",
        "Key": { "execution_id": { "S.$": "$.execution_id" } },
        "UpdateExpression": "SET #s = :s, updated_at = :u, outputs = :o",
        "ExpressionAttributeNames": { "#s": "status" },
        "ExpressionAttributeValues": {
          ":s": { "S": "DONE" },
          ":u": { "S.$": "$$.State.EnteredTime" },
          ":o": {
            "M": {
              "flac": { "S.$": "$.mediaconvert.flac" },
              "playback": { "S.$": "$.mediaconvert.playback" },
              "transcript": { "S.$": "$.transcription.transcript" }
            }
          }
        }
      },
      "ResultPath": null,
      "Retry": [{ "ErrorEquals": ["States.TaskFailed"], "IntervalSeconds": 2, "MaxAttempts": 3, "BackoffRate": 2 }],
      "Catch": [{ "ErrorEquals": ["States.ALL"], "ResultPath": "$.error", "Next": "MarkFailedTechnical" }],
      "Next": "Done"
    },

    "Done": { "Type": "Succeed" },

    "ParseLambdaError": {
      "Type": "Pass",
      "Parameters": { "cause.$": "States.StringToJson($.error.Cause)" },
      "ResultPath": "$.parsed",
      "Next": "ShapeLambdaFailure"
    },

    "ShapeLambdaFailure": {
      "Type": "Pass",
      "Parameters": {
        "code.$": "$.error.Error",
        "message.$": "$.parsed.cause.errorMessage"
      },
      "ResultPath": "$.failure",
      "Next": "MarkFailedBusiness"
    },

    "ShapePlainFailure": {
      "Type": "Pass",
      "Parameters": {
        "code.$": "$.error.Error",
        "message.$": "$.error.Cause"
      },
      "ResultPath": "$.failure",
      "Next": "MarkFailedBusiness"
    },

    "MarkFailedBusiness": {
      "Type": "Task",
      "Resource": "arn:aws:states:::dynamodb:updateItem",
      "Parameters": {
        "TableName": "__PREFIX__-executions",
        "Key": { "execution_id": { "S.$": "$.execution_id" } },
        "UpdateExpression": "SET #s = :s, updated_at = :u, #e = :e",
        "ExpressionAttributeNames": { "#s": "status", "#e": "error" },
        "ExpressionAttributeValues": {
          ":s": { "S": "FAILED" },
          ":u": { "S.$": "$$.State.EnteredTime" },
          ":e": {
            "M": {
              "code": { "S.$": "$.failure.code" },
              "message": { "S.$": "$.failure.message" }
            }
          }
        }
      },
      "ResultPath": null,
      "Retry": [{ "ErrorEquals": ["States.TaskFailed"], "IntervalSeconds": 2, "MaxAttempts": 3, "BackoffRate": 2 }],
      "Catch": [{ "ErrorEquals": ["States.ALL"], "ResultPath": "$.error", "Next": "MarkFailedTechnical" }],
      "Next": "FailedBusiness"
    },

    "FailedBusiness": { "Type": "Succeed" },

    "MarkFailedTechnical": {
      "Type": "Task",
      "Resource": "arn:aws:states:::dynamodb:updateItem",
      "Parameters": {
        "TableName": "__PREFIX__-executions",
        "Key": { "execution_id": { "S.$": "$.execution_id" } },
        "UpdateExpression": "SET #s = :s, updated_at = :u, #e = :e",
        "ExpressionAttributeNames": { "#s": "status", "#e": "error" },
        "ExpressionAttributeValues": {
          ":s": { "S": "FAILED" },
          ":u": { "S.$": "$$.State.EnteredTime" },
          ":e": {
            "M": {
              "code": { "S": "ProcessingFailed" },
              "message": { "S": "An internal error occurred while processing the file." }
            }
          }
        }
      },
      "ResultPath": null,
      "Retry": [{ "ErrorEquals": ["States.TaskFailed"], "IntervalSeconds": 2, "MaxAttempts": 3, "BackoffRate": 2 }],
      "Catch": [{ "ErrorEquals": ["States.ALL"], "ResultPath": "$.markError", "Next": "NotifyTeam" }],
      "Next": "NotifyTeam"
    },

    "NotifyTeam": {
      "Type": "Task",
      "Resource": "arn:aws:states:::sns:publish",
      "Parameters": {
        "TopicArn": "arn:aws:sns:__REGION__:__ACCOUNT_ID__:__PREFIX__-alerts",
        "Subject": "STT pipeline failure",
        "Message.$": "States.Format('STT pipeline failure | execution_id: {} | input: {} | error: {} | cause: {} | console: https://__REGION__.console.aws.amazon.com/states/home?region=__REGION__#/v2/executions/details/{}', $.execution_id, $.input, $.error.Error, $.error.Cause, $$.Execution.Id)"
      },
      "ResultPath": null,
      "Retry": [{ "ErrorEquals": ["States.TaskFailed"], "IntervalSeconds": 2, "MaxAttempts": 3, "BackoffRate": 2 }],
      "Catch": [{ "ErrorEquals": ["States.ALL"], "ResultPath": "$.notifyError", "Next": "ExecutionFailed" }],
      "Next": "ExecutionFailed"
    },

    "ExecutionFailed": {
      "Type": "Fail",
      "ErrorPath": "$.error.Error",
      "CausePath": "$.error.Cause"
    }
  }
}
