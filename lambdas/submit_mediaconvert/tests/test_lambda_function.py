import io
import json
import os
import subprocess
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
os.environ.setdefault("AWS_DEFAULT_REGION", "eu-central-1")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "test")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "test")

import lambda_function as lf  # noqa: E402

TEMPLATE = {
    "Role": "arn:role",
    "Queue": "arn:queue",
    "Settings": {
        "Inputs": [{"FileInput": "s3://x/REPLACE"}],
        "OutputGroups": [
            {"OutputGroupSettings": {"FileGroupSettings": {"Destination": "s3://x/output/"}}}
        ],
    },
}


def event(**kw):
    base = {"execution_id": "exec-1", "task_token": "TOKEN", "bucket": "stt-tests-wacef", "key": "input/a.mp3"}
    base.update(kw)
    return base


def stream(channels):
    return [{"channels": channels, "channel_layout": "stereo", "codec_name": "mp3", "sample_rate": "44100"}]


class SubmitMediaConvertTest(unittest.TestCase):
    def setUp(self):
        patches = {
            "s3": mock.patch.object(lf, "s3"),
            "mc": mock.patch.object(lf, "mediaconvert"),
            "sfn": mock.patch.object(lf, "sfn"),
            "tasks": mock.patch.object(lf, "tasks_table"),
            "execs": mock.patch.object(lf, "executions_table"),
            "probe": mock.patch.object(lf, "_probe_audio_streams"),
        }
        m = {name: p.start() for name, p in patches.items()}
        self.addCleanup(mock.patch.stopall)
        self.s3, self.mc, self.sfn = m["s3"], m["mc"], m["sfn"]
        self.tasks, self.execs, self.probe = m["tasks"], m["execs"], m["probe"]
        self.s3.get_object.side_effect = lambda **kw: {"Body": io.BytesIO(json.dumps(TEMPLATE).encode())}
        self.mc.create_job.return_value = {"Job": {"Id": "job-1", "Status": "SUBMITTED"}}

    def test_mono(self):
        self.probe.return_value = stream(1)
        out = lf.lambda_handler(event(), None)
        self.assertEqual((out["template"], out["job_id"]), ("mono", "job-1"))
        self.assertEqual(self.s3.get_object.call_args.kwargs["Key"], "templates/job-mono.json")

    def test_job_content(self):
        self.probe.return_value = stream(1)
        lf.lambda_handler(event(), None)
        job = self.mc.create_job.call_args.kwargs
        self.assertEqual(job["Settings"]["Inputs"][0]["FileInput"], "s3://stt-tests-wacef/input/a.mp3")
        dest = job["Settings"]["OutputGroups"][0]["OutputGroupSettings"]["FileGroupSettings"]["Destination"]
        self.assertEqual(dest, "s3://stt-tests-wacef/output/exec-1/")
        self.assertEqual(job["UserMetadata"]["execution_id"], "exec-1")

    def test_token_stored_before_job(self):
        self.probe.return_value = stream(1)
        calls = mock.Mock()
        calls.attach_mock(self.tasks.put_item, "put_token")
        calls.attach_mock(self.mc.create_job, "create_job")
        lf.lambda_handler(event(), None)
        self.assertEqual([c[0] for c in calls.mock_calls], ["put_token", "create_job"])
        item = self.tasks.put_item.call_args.kwargs["Item"]
        self.assertEqual((item["execution_id"], item["stage"], item["task_token"]), ("exec-1", "MEDIACONVERT", "TOKEN"))
        self.assertEqual((item["channels"], item["template"]), (1, "mono"))

    def test_stereo_modes(self):
        self.probe.return_value = stream(2)
        self.assertEqual(lf.lambda_handler(event(), None)["template"], "stereo-downmix")
        self.assertEqual(lf.lambda_handler(event(stereo_mode="keep"), None)["template"], "stereo-keep")

    def test_execution_tracking_updated(self):
        self.probe.return_value = stream(1)
        lf.lambda_handler(event(), None)
        vals = self.execs.update_item.call_args.kwargs["ExpressionAttributeValues"]
        self.assertEqual(vals[":j"], "job-1")

    def test_no_audio_reports_failure_to_step_functions(self):
        self.probe.return_value = []
        out = lf.lambda_handler(event(), None)
        self.assertEqual(out["error"], "NoAudioStream")
        self.sfn.send_task_failure.assert_called_once()
        self.assertEqual(self.sfn.send_task_failure.call_args.kwargs["error"], "NoAudioStream")
        self.mc.create_job.assert_not_called()
        self.tasks.put_item.assert_not_called()

    def test_unsupported_channels(self):
        self.probe.return_value = stream(6)
        out = lf.lambda_handler(event(), None)
        self.assertEqual(out["error"], "UnsupportedChannels")

    def test_keep_with_speaker_labels_rejected(self):
        self.probe.return_value = stream(2)
        out = lf.lambda_handler(event(stereo_mode="keep", transcribe={"max_speaker_labels": 2}), None)
        self.assertEqual(out["error"], "InvalidParameters")
        self.mc.create_job.assert_not_called()

    def test_speaker_labels_ok_on_mono_and_downmix(self):
        self.probe.return_value = stream(1)
        self.assertEqual(lf.lambda_handler(event(transcribe={"max_speaker_labels": 2}), None)["template"], "mono")
        self.probe.return_value = stream(2)
        out = lf.lambda_handler(event(transcribe={"max_speaker_labels": 2}), None)
        self.assertEqual(out["template"], "stereo-downmix")

    def test_unreadable_media_is_business_failure(self):
        self.probe.side_effect = lf.InputInvalid("bad media")
        out = lf.lambda_handler(event(), None)
        self.assertEqual(out["error"], "InputInvalid")

    def test_technical_error_cleans_token_and_raises(self):
        self.probe.return_value = stream(1)
        self.mc.create_job.side_effect = RuntimeError("boom")
        with self.assertRaises(RuntimeError):
            lf.lambda_handler(event(), None)
        self.tasks.delete_item.assert_called_once()
        self.sfn.send_task_failure.assert_not_called()

    def test_probe_timeout_is_technical(self):
        self.probe.side_effect = subprocess.TimeoutExpired("ffprobe", 60)
        with self.assertRaises(subprocess.TimeoutExpired):
            lf.lambda_handler(event(), None)
        self.sfn.send_task_failure.assert_not_called()

    def test_missing_fields(self):
        with self.assertRaises(ValueError):
            lf.lambda_handler({"execution_id": "e"}, None)

    def test_invalid_stereo_mode(self):
        out = lf.lambda_handler(event(stereo_mode="both"), None)
        self.assertEqual(out["error"], "InvalidParameters")
        self.sfn.send_task_failure.assert_called_once()


if __name__ == "__main__":
    unittest.main()
