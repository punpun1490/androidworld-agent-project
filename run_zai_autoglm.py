"""Launch Z.AI Open-AutoGLM through AndroidWorld's stock task evaluator."""
import run as androidworld_run
from zai_androidworld_agent import ZaiAndroidWorldAgent

_original_get_agent = androidworld_run._get_agent


def _get_agent(env, family=None):
    if androidworld_run._AGENT_NAME.value == "zai_autoglm_phone":
        return ZaiAndroidWorldAgent(env)
    return _original_get_agent(env, family)


androidworld_run._get_agent = _get_agent

if __name__ == "__main__":
    androidworld_run.app.run(androidworld_run.main)
