FROM docker.io/vllm/vllm-tpu:2e33fe419186c65a18da6668972d61d7bbc31564
COPY tpu_entrypoint.sh /vllm-workspace/tpu_entrypoint.sh
RUN chmod +x /vllm-workspace/tpu_entrypoint.sh
ENTRYPOINT [ "/vllm-workspace/tpu_entrypoint.sh" ]