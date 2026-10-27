import json
import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
os.environ.setdefault("AWS_DEFAULT_REGION", "eu-central-1")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "test")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "test")

from botocore.exceptions import ClientError  # noqa: E402

import lambda_function as lf  # noqa: E402


def mc_event(status="COMPLETE", execution_id="exec-1", **detail):
    d = {
        "status": status,
        "jobId": "job-1",
        "userMetadata": {"execution_id": execution_id} if execution_id else {},
        "outputGroupDetails": [
            {
                "outputDetails": [
                    {"outputFilePaths": ["s3://b/output/exec-1/a_flac48k_mono.flac"]},
                    {"outputFilePaths": ["s3://b/output/exec-1/a_playback.mp4"]},
                ]
            }
        ],
    }
    d.update(detail)
    return {"source": "aws.mediaconvert", "detail-type": "MediaConvert Job State Change", "detail": d}


def tr_event(status="COMPLETED", name="stt-exec-1", **detail):
    d = {"TranscriptionJobName": name, "TranscriptionJobStatus": status}
    d.update(detail)
    return {"source": "aws.transcribe", "detail-type": "Transcribe Job State Change", "detail": d}


def client_error(code):
    return ClientError({"Error": {"Code": code, "Message": code}}, "SendTaskSuccess")


MC_ITEM = {"execution_id": "exec-1", "stage": "MEDIACONVERT", "task_token": "T1",
           "channels": 2, "template": "stereo-keep", "stereo_mode": "keep"}
TR_ITEM = {"execution_id": "exec-1", "stage": "TRANSCRIBE", "task_token": "T2",
           "transcript_uri": "s3://b/transcripts/exec-1/transcript.json"}


class CallbackTest(unittest.TestCase):
    def setUp(self):
        self.sfn = mock.patch.object(lf, "sfn").start()
        self.table = mock.patch.object(lf, "tasks_table").start()
        self.addCleanup(mock.patch.stopall)
        self.table.get_item.return_value = {"Item": MC_ITEM}

    def test_mediaconvert_success(self):
        out = lf.lambda_handler(mc_event(), None)
        self.assertEqual(out["status"], "success")
        args = self.sfn.send_task_success.call_args.kwargs
        self.assertEqual(args["taskToken"], "T1")
        payload = json.loads(args["output"])
        self.assertEqual(payload["flac"], "s3://b/output/exec-1/a_flac48k_mono.flac")
        self.assertEqual(payload["playback"], "s3://b/output/exec-1/a_playback.mp4")
        self.assertEqual((payload["channels"], payload["template"]), (2, "stereo-keep"))
        self.table.delete_item.assert_called_once_with(Key={"execution_id": "exec-1", "stage": "MEDIACONVERT"})

    def test_mediaconvert_lookup_key(self):
        lf.lambda_handler(mc_event(), None)
        self.assertEqual(self.table.get_item.call_args.kwargs["Key"], {"execution_id": "exec-1", "stage": "MEDIACONVERT"})

    def test_mediaconvert_error(self):
        out = lf.lambda_handler(mc_event("ERROR", errorCode=1010, errorMessage="Bad input"), None)
        self.assertEqual(out["status"], "failure")
        args = self.sfn.send_task_failure.call_args.kwargs
        self.assertEqual(args["error"], "MediaConvertJobFailed")
        self.assertEqual(args["cause"], "1010: Bad input")
        self.sfn.send_task_success.assert_not_called()

    def test_mediaconvert_canceled(self):
        lf.lambda_handler(mc_event("CANCELED"), None)
        self.assertEqual(self.sfn.send_task_failure.call_args.kwargs["error"], "MediaConvertJobCanceled")

    def test_complete_without_flac_is_failure(self):
        lf.lambda_handler(mc_event(outputGroupDetails=[]), None)
        self.assertEqual(self.sfn.send_task_failure.call_args.kwargs["error"], "OutputMissing")

    def test_transcribe_success(self):
        self.table.get_item.return_value = {"Item": TR_ITEM}
        out = lf.lambda_handler(tr_event(), None)
        self.assertEqual(out["status"], "success")
        self.assertEqual(self.table.get_item.call_args.kwargs["Key"], {"execution_id": "exec-1", "stage": "TRANSCRIBE"})
        payload = json.loads(self.sfn.send_task_success.call_args.kwargs["output"])
        self.assertEqual(payload["transcript"], "s3://b/transcripts/exec-1/transcript.json")

    def test_transcribe_failure(self):
        self.table.get_item.return_value = {"Item": TR_ITEM}
        lf.lambda_handler(tr_event("FAILED", FailureReason="Unsupported language"), None)
        args = self.sfn.send_task_failure.call_args.kwargs
        self.assertEqual((args["error"], args["cause"]), ("TranscribeJobFailed", "Unsupported language"))

    def test_ignored_events(self):
        cases = [
            mc_event(execution_id=None),
            mc_event("PROGRESSING"),
            tr_event(name="other-job"),
            tr_event("IN_PROGRESS"),
            {"source": "aws.s3", "detail": {}},
        ]
        for ev in cases:
            self.assertEqual(lf.lambda_handler(ev, None)["status"], "ignored", ev)
        self.sfn.send_task_success.assert_not_called()
        self.sfn.send_task_failure.assert_not_called()

    def test_duplicate_event_without_pending_task(self):
        self.table.get_item.return_value = {}
        self.assertEqual(lf.lambda_handler(mc_event(), None)["reason"], "no pending task")
        self.sfn.send_task_success.assert_not_called()

    def test_stale_token_is_cleaned_without_error(self):
        for code in ("TaskDoesNotExist", "TaskTimedOut", "InvalidToken"):
            self.sfn.send_task_success.side_effect = client_error(code)
            self.table.delete_item.reset_mock()
            self.assertEqual(lf.lambda_handler(mc_event(), None)["status"], "stale")
            self.table.delete_item.assert_called_once()

    def test_other_aws_error_is_raised_and_item_kept(self):
        self.sfn.send_task_success.side_effect = client_error("ThrottlingException")
        with self.assertRaises(ClientError):
            lf.lambda_handler(mc_event(), None)
        self.table.delete_item.assert_not_called()


if __name__ == "__main__":
    unittest.main()
