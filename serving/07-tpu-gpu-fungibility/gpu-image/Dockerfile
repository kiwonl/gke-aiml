FROM docker.io/vllm/vllm-openai:latest
COPY gpu_entrypoint.sh /vllm-workspace/gpu_entrypoint.sh
RUN chmod +x /vllm-workspace/gpu_entrypoint.sh
ENTRYPOINT [ "/vllm-workspace/gpu_entrypoint.sh" ]