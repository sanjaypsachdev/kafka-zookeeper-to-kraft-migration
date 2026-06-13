import os
from dataclasses import dataclass, field

from dotenv import load_dotenv
from langchain_core.language_models import BaseChatModel

load_dotenv()


@dataclass
class Settings:
    # LLM provider: "anthropic" or "openai"
    llm_provider: str = field(default_factory=lambda: os.getenv("LLM_PROVIDER", "anthropic"))
    llm_model: str = field(default_factory=lambda: os.getenv("LLM_MODEL", "claude-opus-4-8"))

    # Anthropic
    anthropic_api_key: str = field(default_factory=lambda: os.getenv("ANTHROPIC_API_KEY", ""))

    # OpenAI / OpenAI-compatible
    openai_api_key: str = field(default_factory=lambda: os.getenv("OPENAI_API_KEY", ""))
    openai_base_url: str = field(default_factory=lambda: os.getenv("OPENAI_BASE_URL", ""))


def get_llm(settings: Settings | None = None) -> BaseChatModel:
    """Return a LangChain chat model based on the configured provider."""
    if settings is None:
        settings = Settings()

    provider = settings.llm_provider.lower()

    if provider == "anthropic":
        from langchain_anthropic import ChatAnthropic

        if not settings.anthropic_api_key:
            raise ValueError("ANTHROPIC_API_KEY is not set. Add it to your .env file.")
        return ChatAnthropic(
            model=settings.llm_model,
            api_key=settings.anthropic_api_key,
        )

    elif provider == "openai":
        from langchain_openai import ChatOpenAI

        if not settings.openai_api_key:
            raise ValueError("OPENAI_API_KEY is not set. Add it to your .env file.")
        kwargs: dict = {
            "model": settings.llm_model,
            "api_key": settings.openai_api_key,
        }
        if settings.openai_base_url:
            # Enables any OpenAI-compatible endpoint: Azure, Ollama, vLLM, etc.
            kwargs["base_url"] = settings.openai_base_url
        return ChatOpenAI(**kwargs)

    else:
        raise ValueError(
            f"Unknown LLM_PROVIDER: {settings.llm_provider!r}. "
            "Set LLM_PROVIDER to 'anthropic' or 'openai' in your .env file."
        )
