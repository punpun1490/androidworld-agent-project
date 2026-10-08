"""Run the stock AndroidWorld M3A agent with the Gemini AI Studio adapter.

Patch only AndroidWorld's agent factory; leave its task setup/verifier unchanged.
"""
import os
import sys

import run as androidworld_run
from android_world.agents import m3a
from ai_studio_agent import GeminiStudioWrapper

original_get_agent = androidworld_run._get_agent

def get_agent(env, family=None):
    if androidworld_run._AGENT_NAME.value == "m3a_ai_studio":
        agent = m3a.M3A(env, GeminiStudioWrapper())
        agent.name = "m3a_ai_studio"
        return agent
    return original_get_agent(env, family)

androidworld_run._get_agent = get_agent

if __name__ == "__main__":
    androidworld_run.app.run(androidworld_run.main)
