"""Persistent macOS USB-device QA agent for FaceSwapLiveAppV17."""

from .config import AgentConfig
from .models import (
    Artifact,
    DeviceInfo,
    Job,
    JobRequest,
    JobStatus,
    RunResult,
    Target,
    TargetKind,
)

__version__ = "0.1.0"

__all__ = [
    "AgentConfig",
    "Artifact",
    "DeviceInfo",
    "Job",
    "JobRequest",
    "JobStatus",
    "RunResult",
    "Target",
    "TargetKind",
    "__version__",
]
