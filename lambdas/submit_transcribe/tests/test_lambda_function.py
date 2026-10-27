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

FLAC = "s3://stt-tests-wacef/output/exec-1/a_flac48k_mono.flac"


def event(**kw):
    base = {
        "execution_id": "exec-1",
        "task_token": "TOKEN",
        "flac": FLAC,
        "template": "mono",
        "transcribe": {"language_code": "fr-FR"},
    }
    base.update(kw)
    return base


def client_error(code, message="msg"):
    return ClientError({"Error": {"Code": code, "Message": message}}, "StartTranscriptionJob")


class SubmitTranscribeTest(unittest.TestCase):
    def setUp(self):
        self.tr = mock.patch.object(lf, "transcribe").start()
        self.sfn = mock.patch.object(lf, "sfn").start()
        self.tasks = mock.patch.object(lf, "tasks_table").start()
        self.execs = mock.patch.object(lf, "executions_table").start()
        self.addCleanup(mock.patch.stopall)

    def request(self):
        return self.tr.start_transcription_job.call_args.kwargs

    def test_basic_request(self):
        out = lf.lambda_handler(event(), None)
        req = self.request()
        self.assertEqual(req["TranscriptionJobName"], "stt-exec-1")
        self.assertEqual(req["Media"], {"MediaFileUri": FLAC})
        self.assertEqual(req["MediaFormat"], "flac")
        self.assertEqual(req["LanguageCode"], "fr-FR")
        self.assertEqual(req["OutputBucketName"], "stt-tests-wacef")
        self.assertEqual(req["OutputKey"], "transcripts/exec-1/transcript.json")
        self.assertNotIn("Settings", req)
        self.assertEqual(out["transcript_uri"], "s3://stt-tests-wacef/transcripts/exec-1/transcript.json")

    def test_token_stored_before_job_with_transcript_uri(self):
        calls = mock.Mock()
        calls.attach_mock(self.tasks.put_item, "put_token")
        calls.attach_mock(self.tr.start_transcription_job, "start_job")
        lf.lambda_handler(event(), None)
        self.assertEqual([c[0] for c in calls.mock_calls], ["put_token", "start_job"])
        item = self.tasks.put_item.call_args.kwargs["Item"]
        self.assertEqual((item["execution_id"], item["stage"], item["task_token"]), ("exec-1", "TRANSCRIBE", "TOKEN"))
        self.assertEqual(item["transcript_uri"], "s3://stt-tests-wacef/transcripts/exec-1/transcript.json")

    def test_identify_language(self):
        lf.lambda_handler(event(transcribe={"identify_language": True, "language_options": ["fr-FR", "en-US"]}), None)
        req = self.request()
        self.assertTrue(req["IdentifyLanguage"])
        self.assertEqual(req["LanguageOptions"], ["fr-FR", "en-US"])
        self.assertNotIn("LanguageCode", req)

    def test_speaker_labels(self):
        lf.lambda_handler(event(transcribe={"language_code": "fr-FR", "max_speaker_labels": 3}), None)
        self.assertEqual(self.request()["Settings"], {"ShowSpeakerLabels": True, "MaxSpeakerLabels": 3})

    def test_channel_identification_for_stereo_keep(self):
        out = lf.lambda_handler(event(template="stereo-keep"), None)
        self.assertEqual(self.request()["Settings"], {"ChannelIdentification": True})
        self.assertTrue(out["channel_identification"])

    def test_stereo_downmix_has_no_channel_identification(self):
        lf.lambda_handler(event(template="stereo-downmix"), None)
        self.assertNotIn("Settings", self.request())

    def test_keep_with_speaker_labels_is_business_failure(self):
        out = lf.lambda_handler(
            event(template="stereo-keep", transcribe={"language_code": "fr-FR", "max_speaker_labels": 2}), None
        )
        self.assertEqual(out["error"], "InvalidParameters")
        self.sfn.send_task_failure.assert_called_once()
        self.tr.start_transcription_job.assert_not_called()
        self.tasks.put_item.assert_not_called()

    def test_vocabulary(self):
        lf.lambda_handler(event(transcribe={"language_code": "fr-FR", "vocabulary_name": "voc"}), None)
        self.assertEqual(self.request()["Settings"], {"VocabularyName": "voc"})

    def test_language_required(self):
        out = lf.lambda_handler(event(transcribe={}), None)
        self.assertEqual(out["error"], "InvalidParameters")

    def test_bad_media_uri(self):
        for uri in ("http://x/a.flac", "s3://other/a.flac", "s3://stt-tests-wacef/"):
            out = lf.lambda_handler(event(flac=uri), None)
            self.assertEqual(out["error"], "InputInvalid", uri)

    def test_bad_request_from_transcribe_is_business_failure(self):
        self.tr.start_transcription_job.side_effect = client_error("BadRequestException", "vocabulary not found")
        out = lf.lambda_handler(event(), None)
        self.assertEqual(out["error"], "InvalidParameters")
        self.tasks.delete_item.assert_called_once()
        self.assertIn("vocabulary", self.sfn.send_task_failure.call_args.kwargs["cause"])

    def test_conflict_reuses_existing_job(self):
        self.tr.start_transcription_job.side_effect = client_error("ConflictException")
        out = lf.lambda_handler(event(), None)
        self.assertEqual(out["job_name"], "stt-exec-1")
        self.sfn.send_task_failure.assert_not_called()
        self.tasks.delete_item.assert_not_called()

    def test_technical_error_cleans_token_and_raises(self):
        for code in ("LimitExceededException", "InternalFailureException"):
            self.tasks.delete_item.reset_mock()
            self.tr.start_transcription_job.side_effect = client_error(code)
            with self.assertRaises(ClientError):
                lf.lambda_handler(event(), None)
            self.tasks.delete_item.assert_called_once()
        self.sfn.send_task_failure.assert_not_called()

    def test_execution_tracking_updated(self):
        lf.lambda_handler(event(), None)
        vals = self.execs.update_item.call_args.kwargs["ExpressionAttributeValues"]
        self.assertEqual(vals[":n"], "stt-exec-1")

    def test_missing_fields(self):
        with self.assertRaises(ValueError):
            lf.lambda_handler({"execution_id": "e", "task_token": "t"}, None)


if __name__ == "__main__":
    unittest.main()
