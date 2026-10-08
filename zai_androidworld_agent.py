"""Adapter: run official Z.AI Open-AutoGLM PhoneAgent inside AndroidWorld.

PhoneAgent captures/screens and acts through ADB. AndroidWorld owns task
initialization, the step budget, verification and its trajectory checkpointer.
All paid API calls use PHONE_AGENT_API_KEY from a GitHub Actions secret.
"""
import json
import os

from android_world.agents import base_agent
from phone_agent import PhoneAgent
from phone_agent.agent import AgentConfig
from phone_agent.model import ModelConfig


def _refuse_takeover(message):
    raise RuntimeError(
        "AutoGLM requested human takeover; unattended benchmark stopped"
    )


class ZaiAndroidWorldAgent(base_agent.EnvironmentInteractingAgent):
    def __init__(self, env):
        super().__init__(env, name="zai_autoglm_phone")
        key = os.environ.get("PHONE_AGENT_API_KEY")
        if not key:
            raise RuntimeError("Missing PHONE_AGENT_API_KEY (ZAI_API_KEY GitHub secret)")
        lang = os.environ.get("PHONE_AGENT_LANG", "en")
        model_cfg = ModelConfig(
            base_url=os.environ.get(
                "PHONE_AGENT_BASE_URL", "https://api.z.ai/api/paas/v4"
            ),
            model_name=os.environ.get(
                "PHONE_AGENT_MODEL", "autoglm-phone-multilingual"
            ),
            api_key=key,
            lang=lang,
            temperature=0.0,
        )
        agent_cfg = AgentConfig(
            device_id=os.environ.get("PHONE_AGENT_DEVICE_ID", "emulator-5554"),
            lang=lang,
            max_steps=100,
            verbose=True,
        )
        self.phone = PhoneAgent(
            model_config=model_cfg,
            agent_config=agent_cfg,
            confirmation_callback=lambda message: False,
            takeover_callback=_refuse_takeover,
        )
        self._first_step = True

    def reset(self, go_home=False):
        super().reset(go_home=go_home)
        self.phone.reset()
        self._first_step = True

    def step(self, goal):
        screenshot = self.get_post_transition_state().pixels.copy()
        result = self.phone.step(goal if self._first_step else None)
        self._first_step = False
        if result.finished and (result.message or "").startswith("Model error:"):
            raise RuntimeError("AutoGLM model API request failed; see agent logs")

        action = result.action or {}
        return base_agent.AgentInteractionResult(
            done=result.finished,
            data={
                "raw_screenshot": screenshot,
                "before_screenshot_with_som": screenshot,
                "action_output": json.dumps(action, ensure_ascii=False),
                "action_output_json": action,
                "action_reason": result.thinking,
                "summary": result.message or "",
                "action_success": result.success,
            },
        )
