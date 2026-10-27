import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
os.environ.setdefault("AWS_DEFAULT_REGION", "eu-central-1")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "test")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "test")

from botocore.stub import Stubber  # noqa: E402

import lambda_function as lf  # noqa: E402


def _event(uri="s3://stt-tests-wacef/input/a.mp3"):
    return {"execution_id": "e1", "input": uri}


class ValidateInputTest(unittest.TestCase):
    def setUp(self):
        self.stub = Stubber(lf.s3)
        self.stub.activate()

    def tearDown(self):
        self.stub.deactivate()

    def test_ok(self):
        self.stub.add_response("head_object", {"ContentLength": 10, "ContentType": "audio/mpeg"},
                               {"Bucket": "stt-tests-wacef", "Key": "input/a.mp3"})
        out = lf.lambda_handler(_event(), None)
        self.assertEqual(out["size_bytes"], 10)
        self.assertEqual(out["extension"], "mp3")

    def test_not_found(self):
        self.stub.add_client_error("head_object", service_error_code="404", http_status_code=404)
        with self.assertRaises(lf.InputNotFound):
            lf.lambda_handler(_event(), None)

    def test_access_denied(self):
        self.stub.add_client_error("head_object", service_error_code="403", http_status_code=403)
        with self.assertRaises(lf.InputInvalid):
            lf.lambda_handler(_event(), None)

    def test_empty_file(self):
        self.stub.add_response("head_object", {"ContentLength": 0})
        with self.assertRaises(lf.InputInvalid):
            lf.lambda_handler(_event(), None)

    def test_transient_error_propagates(self):
        self.stub.add_client_error("head_object", service_error_code="500", http_status_code=500)
        from botocore.exceptions import ClientError
        with self.assertRaises(ClientError):
            lf.lambda_handler(_event(), None)

    def test_bucket_not_allowed(self):
        with self.assertRaises(lf.InputInvalid):
            lf.lambda_handler(_event("s3://other-bucket/a.mp3"), None)

    def test_bad_extension(self):
        with self.assertRaises(lf.InputInvalid):
            lf.lambda_handler(_event("s3://stt-tests-wacef/input/a.txt"), None)

    def test_bad_uri(self):
        for uri in ("http://x/a.mp3", "s3://stt-tests-wacef/", "s3://stt-tests-wacef", None):
            with self.assertRaises(lf.InputInvalid):
                lf.lambda_handler(_event(uri), None)


if __name__ == "__main__":
    unittest.main()
