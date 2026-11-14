"""Offline-only local translation worker; JSON lines over private pipes."""

import contextlib
import json
import os
from pathlib import Path
import sys

os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["TRANSFORMERS_OFFLINE"] = "1"
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
_request_id = None


def emit(event: dict) -> None:
    if _request_id is not None:
        event["request_id"] = _request_id
    print(json.dumps(event, ensure_ascii=False), flush=True)


def messages(request: dict, text: str) -> list[dict]:
    # Translation-specialized Hunyuan models expect a single user instruction.
    if request.get("hunyuan"):
        instruction = (
            f"Translate the following segment into {request['target']}, "
            "without additional explanation."
        )
        return [{"role": "user", "content": instruction + "\n\n" + text}]
    return [
        {"role": "system", "content": request["prompt"]},
        {"role": "user", "content": text},
    ]


def run(request: dict, cache: dict | None = None) -> None:
    path = Path(request["path"])
    if not path.is_absolute() or not path.exists():
        raise ValueError("Missing local model")
    texts = request["texts"]
    if not texts or sum(len(t.encode("utf-8")) for t in texts) > 128 * 1024:
        raise ValueError("Invalid source text")
    if cache is None:
        cache = {}
    key = (str(path), request["format"])
    if cache.get("key") != key:
        cache.clear()
    if request["format"] == "MLX":
        from mlx_lm import load, stream_generate
        from mlx_lm.sample_utils import make_sampler

        if "model" not in cache:
            with contextlib.redirect_stdout(sys.stderr):
                cache["model"], cache["tokenizer"] = load(
                    str(path), tokenizer_config={"trust_remote_code": False, "local_files_only": True}
                )
            cache["key"] = key
        model, tokenizer = cache["model"], cache["tokenizer"]
        for index, text in enumerate(texts):
            prompt = tokenizer.apply_chat_template(
                messages(request, text), tokenize=False, add_generation_prompt=True,
                enable_thinking=False,
            )
            translated = ""
            for response in stream_generate(
                model, tokenizer, prompt, max_tokens=4096, sampler=make_sampler(temp=0)
            ):
                translated += response.text
                emit({"index": index, "text": translated, "finish": response.finish_reason})
    elif request["format"] == "GGUF":
        from llama_cpp import Llama

        if "model" not in cache:
            with contextlib.redirect_stdout(sys.stderr):
                cache["model"] = Llama(model_path=str(path), n_ctx=8192, n_gpu_layers=-1, verbose=False)
            cache["key"] = key
        model = cache["model"]
        for index, text in enumerate(texts):
            translated = ""
            for response in model.create_chat_completion(
                messages=messages(request, text), stream=True, temperature=0, max_tokens=4096
            ):
                choice = response["choices"][0]
                translated += choice["delta"].get("content", "")
                emit({"index": index, "text": translated, "finish": choice.get("finish_reason")})
    else:
        raise ValueError("Unsupported format")
    emit({"event": "finished"})


if __name__ == "__main__":
    cache = {}
    try:
        while line := sys.stdin.buffer.readline(256 * 1024 + 1):
            if len(line) > 256 * 1024:
                raise ValueError("Request too large")
            request = json.loads(line)
            _request_id = request.get("request_id")
            run(request, cache)
            if request["format"] == "MLX":
                import mlx.core as mx
                mx.clear_cache()
            request.clear()
            line = b""
            _request_id = None
            if "--persistent" not in sys.argv:
                break
    except ModuleNotFoundError:
        emit({"error": "runtime"})
        sys.exit(1)
    except (Exception, KeyboardInterrupt):
        # Do not put OCR text or model-specific exception contents into logs.
        emit({"error": "model"})
        sys.exit(1)
