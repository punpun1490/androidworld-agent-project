"""Google AI Studio multimodal adapter for AndroidWorld's existing M3A GUI agent.

This adapter conforms to AndroidWorld's predict_mm(prompt, images) interface.
It never reads or prints the API key. The underlying M3A agent controls the
screenshot / action / observation loop and AndroidWorld verifies final state.
"""
import os
import time

import numpy as np
from PIL import Image
from google import genai
from google.genai import types
from android_world.agents import infer


class GeminiStudioWrapper(infer.LlmWrapper, infer.MultimodalLlmWrapper):
    def __init__(self, model_name=None, max_retries=2, temperature=0.0):
        api_key = os.environ.get("GEMINI_API_KEY")
        if not api_key:
            raise RuntimeError("Missing GitHub Actions secret GEMINI_API_KEY")
        self.model_name = model_name or os.environ.get(
            "GEMINI_MODEL", "gemini-3.5-flash-lite"
        )
        self.client = genai.Client(api_key=api_key)
        self.max_retries = max_retries
        self.config = types.GenerateContentConfig(
            temperature=temperature,
            max_output_tokens=4096,
        )

    def predict(self, text_prompt):
        return self.predict_mm(text_prompt, [])

    def predict_mm(self, text_prompt, images):
        contents = [text_prompt]
        for image in images:
            array = np.asarray(image)
            if array.dtype != np.uint8:
                array = np.clip(array, 0, 255).astype(np.uint8)
            contents.append(Image.fromarray(array).convert("RGB"))

        for attempt in range(self.max_retries + 1):
            try:
                response = self.client.models.generate_content(
                    model=self.model_name,
                    contents=contents,
                    config=self.config,
                )
                answer = (response.text or "").strip()
                if not answer:
                    raise RuntimeError("Gemini produced no text response")
                usage = getattr(response, "usage_metadata", None)
                audit = {
                    "model": self.model_name,
                    "image_count": len(images),
                    "input_tokens": getattr(usage, "prompt_token_count", None),
                    "output_tokens": getattr(usage, "candidates_token_count", None),
                    "response_text": answer,
                }
                return answer, True, audit
            except Exception as exc:
                # Never silently turn an API error into a successful GUI step.
                code = getattr(exc, "code", None)
                status = getattr(exc, "status", None)
                retryable = code in (429, 500, 502, 503, 504) or status in (
                    "RESOURCE_EXHAUSTED", "UNAVAILABLE", "INTERNAL"
                )
                if attempt >= self.max_retries or not retryable:
                    raise RuntimeError(
                        f"Gemini request failed ({type(exc).__name__}, "
                        f"status={status}, code={code})"
                    ) from exc
                time.sleep(min(2 ** attempt * 5, 20))
