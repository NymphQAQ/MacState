"""Exercise both worker backends without downloading models or importing ML libraries."""

import importlib.util
import io
import json
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import patch

WORKER = Path(__file__).resolve().parents[1] / "Sources/MacState/Resources/LocalTranslation/translate.py"
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("local_translation", WORKER)
worker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(worker)


class LocalWorkerTests(unittest.TestCase):
    def test_mlx_uses_only_local_files_and_streams_each_paragraph(self) -> None:
        calls = []
        tokenizer = SimpleNamespace(apply_chat_template=lambda messages, **kw: messages[-1]["content"])

        def load(path, tokenizer_config):
            calls.append((path, tokenizer_config))
            return object(), tokenizer

        def generate(*args, **kwargs):
            yield SimpleNamespace(text="译", finish_reason=None)
            yield SimpleNamespace(text="文", finish_reason="stop")

        modules = {
            "mlx_lm": SimpleNamespace(load=load, stream_generate=generate),
            "mlx_lm.sample_utils": SimpleNamespace(make_sampler=lambda temp: temp),
        }
        with TemporaryDirectory() as folder, patch.dict("sys.modules", modules), patch("sys.stdout", new_callable=io.StringIO) as output:
            worker.run({"path": folder, "format": "MLX", "texts": ["Hello", "World"], "target": "Chinese", "prompt": "Translate"})
            events = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual(calls[0][1], {"trust_remote_code": False, "local_files_only": True})
        self.assertEqual([e["index"] for e in events[:-1]], [0, 0, 1, 1])
        self.assertEqual(events[1]["text"], "译文")
        self.assertEqual(events[-1], {"event": "finished"})

    def test_gguf_stream_preserves_finish_reason_and_uses_local_path(self) -> None:
        calls = []

        class Llama:
            def __init__(self, **kwargs):
                calls.append(kwargs)

            def create_chat_completion(self, **kwargs):
                self.request = kwargs
                yield {"choices": [{"delta": {"content": "partial"}, "finish_reason": None}]}
                yield {"choices": [{"delta": {}, "finish_reason": "length"}]}

        with TemporaryDirectory() as folder, patch.dict("sys.modules", {"llama_cpp": SimpleNamespace(Llama=Llama)}), patch("sys.stdout", new_callable=io.StringIO) as output:
            path = Path(folder) / "model.gguf"
            path.write_bytes(b"GGUFfixture")
            worker.run({"path": str(path), "format": "GGUF", "texts": ["Hello"], "target": "Chinese", "prompt": "Translate"})
            events = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual(calls[0]["model_path"], str(path))
        self.assertEqual(events[1]["finish"], "length")

    def test_hunyuan_uses_one_translation_message(self) -> None:
        messages = worker.messages({"hunyuan": True, "target": "French"}, "Hello")
        self.assertEqual(len(messages), 1)
        self.assertEqual(messages[0]["role"], "user")
        self.assertIn("French", messages[0]["content"])
        self.assertNotIn("Preserve", messages[0]["content"])
        self.assertTrue(messages[0]["content"].endswith("\n\nHello"))

    def test_model_weights_are_reused_but_text_is_not_carried_between_requests(self) -> None:
        loads, prompts = [], []
        tokenizer = SimpleNamespace(apply_chat_template=lambda messages, **kw: prompts.append(messages) or messages[-1]["content"])

        def load(path, tokenizer_config):
            loads.append(path)
            return object(), tokenizer

        def generate(*args, **kwargs):
            yield SimpleNamespace(text="译文", finish_reason="stop")

        modules = {
            "mlx_lm": SimpleNamespace(load=load, stream_generate=generate),
            "mlx_lm.sample_utils": SimpleNamespace(make_sampler=lambda temp: temp),
        }
        with TemporaryDirectory() as folder, patch.dict("sys.modules", modules), patch("sys.stdout", new_callable=io.StringIO):
            cache = {}
            for text in ["First source", "Second source"]:
                worker.run({"path": folder, "format": "MLX", "texts": [text], "target": "Chinese", "prompt": "Translate"}, cache)
        self.assertEqual(len(loads), 1)
        self.assertEqual(prompts[1][-1]["content"], "Second source")
        self.assertNotIn("First source", str(prompts[1]))


if __name__ == "__main__":
    unittest.main()
