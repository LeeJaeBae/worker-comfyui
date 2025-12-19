import unittest
from unittest.mock import MagicMock, patch
import base64
import json

import handler


class TestHandlerValidateInput(unittest.TestCase):
    def test_empty_input(self):
        validated, err = handler.validate_input(None)
        self.assertIsNone(validated)
        self.assertEqual(err, "Please provide input")

    def test_invalid_json_string_input(self):
        validated, err = handler.validate_input("invalid json")
        self.assertIsNone(validated)
        self.assertEqual(err, "Invalid JSON format in input")

    def test_missing_workflow(self):
        validated, err = handler.validate_input({"images": []})
        self.assertIsNone(validated)
        self.assertEqual(err, "Missing 'workflow' parameter")

    def test_invalid_images_structure(self):
        validated, err = handler.validate_input(
            {"workflow": {"key": "value"}, "images": [{"name": "a.png"}]}
        )
        self.assertIsNone(validated)
        self.assertEqual(err, "'images' must be a list of objects with 'name' and 'image' keys")

    def test_valid_workflow_only(self):
        validated, err = handler.validate_input({"workflow": {"key": "value"}})
        self.assertIsNone(err)
        self.assertEqual(
            validated,
            {"workflow": {"key": "value"}, "images": None, "comfy_org_api_key": None},
        )

    def test_valid_workflow_images_and_comfy_org_key(self):
        inp = {
            "workflow": {"key": "value"},
            "images": [{"name": "img.png", "image": "Zg=="}],
            "comfy_org_api_key": "k",
        }
        validated, err = handler.validate_input(inp)
        self.assertIsNone(err)
        self.assertEqual(validated, inp)


class TestHandlerHTTPHelpers(unittest.TestCase):
    @patch("handler.requests.get")
    def test_check_server_up(self, mock_get):
        mock_get.return_value = MagicMock(status_code=200)
        self.assertTrue(handler.check_server("http://127.0.0.1:8188", retries=1, delay=1))

    @patch("handler.requests.get")
    def test_check_server_down(self, mock_get):
        mock_get.side_effect = handler.requests.RequestException("down")
        self.assertFalse(handler.check_server("http://127.0.0.1:8188", retries=1, delay=1))

    @patch("handler.requests.post")
    def test_queue_workflow_success(self, mock_post):
        resp = MagicMock()
        resp.status_code = 200
        resp.raise_for_status.return_value = None
        resp.json.return_value = {"prompt_id": "123"}
        mock_post.return_value = resp

        out = handler.queue_workflow({"1": {"class_type": "Foo"}}, client_id="cid")
        self.assertEqual(out, {"prompt_id": "123"})
        mock_post.assert_called_once()

    @patch("handler.requests.post")
    def test_upload_images_empty(self, mock_post):
        out = handler.upload_images([])
        self.assertEqual(out["status"], "success")
        self.assertEqual(out["message"], "No images to upload")
        mock_post.assert_not_called()

    @patch("handler.requests.post")
    def test_upload_images_success_with_data_uri(self, mock_post):
        resp = MagicMock()
        resp.raise_for_status.return_value = None
        mock_post.return_value = resp

        payload = base64.b64encode(b"abc").decode("utf-8")
        images = [{"name": "x.png", "image": f"data:image/png;base64,{payload}"}]
        out = handler.upload_images(images)
        self.assertEqual(out["status"], "success")
        self.assertEqual(out["message"], "All images uploaded successfully")
        self.assertEqual(len(out["details"]), 1)

    @patch("handler.requests.post")
    def test_upload_images_base64_decode_error(self, mock_post):
        # requests.post should never be called if decode fails first
        out = handler.upload_images([{"name": "x.png", "image": "not_base64!!!"}])
        self.assertEqual(out["status"], "error")
        self.assertEqual(out["message"], "Some images failed to upload")
        self.assertEqual(len(out["details"]), 1)
        mock_post.assert_not_called()

    @patch("handler.requests.post")
    def test_upload_images_http_error(self, mock_post):
        mock_post.side_effect = handler.requests.RequestException("boom")
        payload = base64.b64encode(b"abc").decode("utf-8")
        out = handler.upload_images([{"name": "x.png", "image": payload}])
        self.assertEqual(out["status"], "error")
        self.assertEqual(out["message"], "Some images failed to upload")
        self.assertEqual(len(out["details"]), 1)
