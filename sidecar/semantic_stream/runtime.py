"""Offline CPU Stream classifier used only for the Step 17 experiment."""
import time
from pathlib import Path

from stream_models import verify

SEVERITIES = {"Safe", "Unsafe", "Controversial"}


class StreamGuard:
    def __init__(self, directory, threads=2):
        import torch
        from transformers import AutoModel, AutoTokenizer
        verify(directory)
        torch.set_num_threads(threads)
        self.torch = torch
        self.tokenizer = AutoTokenizer.from_pretrained(Path(directory), local_files_only=True)
        # Both architecture files are pinned and verified along with the weights.
        self.model = AutoModel.from_pretrained(Path(directory), local_files_only=True,
            trust_remote_code=True, dtype=torch.float32, attn_implementation="eager").to("cpu").eval()

    def classify(self, prompt, response, deadline):
        user = [{"role": "user", "content": prompt}]
        messages = user + [{"role": "assistant", "content": response}]
        rendered = self.tokenizer.apply_chat_template(messages, tokenize=False,
            add_generation_prompt=False, enable_thinking=False)
        user_ids = self.tokenizer.apply_chat_template(user, tokenize=True,
            add_generation_prompt=False, enable_thinking=False)
        ids = self.tokenizer(rendered, return_tensors="pt")["input_ids"][0]
        if ids.shape[0] > self.model.config.max_position_embeddings:
            raise ValueError("context_limit")
        if ids[:len(user_ids)].tolist() != user_ids:
            raise ValueError("tokenizer_prefix_mismatch")
        labels, first_unsafe, state = [], None, None
        started = time.monotonic()
        try:
            with self.torch.inference_mode():
                _, state = self.model.stream_moderate_from_ids(ids[:len(user_ids)], role="user")
                for index, token in enumerate(ids[len(user_ids):], start=1):
                    if time.monotonic() >= deadline:
                        raise ValueError("deadline")
                    result, state = self.model.stream_moderate_from_ids(token, role="assistant", stream_state=state)
                    label = result["risk_level"][-1]
                    if label not in SEVERITIES:
                        raise ValueError("invalid_model_result")
                    labels.append(label)
                    if label == "Unsafe" and first_unsafe is None:
                        first_unsafe = {"assistant_token_index": index,
                            "elapsed_us": round((time.monotonic() - started) * 1_000_000)}
        finally:
            self.model.close_stream(state)
        return {"blocked": "Unsafe" in labels, "final_severity": labels[-1] if labels else "Safe",
            "first_unsafe": first_unsafe, "assistant_tokens": len(labels)}
