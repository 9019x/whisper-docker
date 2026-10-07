# syntax=docker/dockerfile:1

ARG PYTHON_VERSION=3.13
ARG WHISPER_VERSION=20250625
# PyTorch wheel index: cpu, or a GPU build such as cu130 / cu126 / rocm7.2.
ARG TORCH_INDEX=cpu

# --- build: resolve wheels into a self-contained venv --------------------
FROM python:${PYTHON_VERSION}-slim-trixie AS build
ARG WHISPER_VERSION
ARG TORCH_INDEX
# GPU wheels run to gigabytes; keep resuming dropped downloads.
ENV PATH=/opt/venv/bin:$PATH PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_RESUME_RETRIES=50

RUN python -m venv /opt/venv
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --index-url https://download.pytorch.org/whl/${TORCH_INDEX} torch \
 && pip install openai-whisper==${WHISPER_VERSION}

# Whisper's metadata pulls NVIDIA's `triton`, which overwrites the same module
# from ROCm torch's `triton-rocm`. On ROCm builds, put the ROCm one back.
RUN --mount=type=cache,target=/root/.cache/pip \
    if v=$(pip show triton-rocm 2>/dev/null | sed -n 's/^Version: //p') && [ -n "$v" ]; then \
      pip uninstall -y triton \
   && pip install --force-reinstall --no-deps \
        --index-url https://download.pytorch.org/whl/${TORCH_INDEX} "triton-rocm==$v"; \
    fi

# --- runtime: ffmpeg + the venv, nothing else ----------------------------
FROM python:${PYTHON_VERSION}-slim-trixie

RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg \
 && rm -rf /var/lib/apt/lists/*

COPY --from=build /opt/venv /opt/venv

# Models land in $XDG_CACHE_HOME/whisper -- mount /cache to keep them.
ENV PATH=/opt/venv/bin:$PATH XDG_CACHE_HOME=/cache
RUN useradd --create-home --uid 1000 whisper && install -d -o whisper /cache

USER whisper
WORKDIR /audio
ENTRYPOINT ["whisper"]
CMD ["--help"]
