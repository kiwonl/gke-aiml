#!/usr/bin/env bash

if ! [ -c /dev/vfio/0 ]; then
    echo "machine doesn't contain TPU machines, shutting down container"
    while true; do sleep 10000; done
fi

python3 -m vllm.entrypoints.openai.api_server $@
