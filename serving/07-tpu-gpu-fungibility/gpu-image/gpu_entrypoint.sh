#!/usr/bin/env bash

if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "machine doesn't contain GPU machines, shutting down container"
    sleep 9999 & wait
fi

python3 -m vllm.entrypoints.openai.api_server $@
