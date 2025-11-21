# Serving Gemma 3 on GKE with vLLM, GPU and Hyperdisk ML

```
.
├── README.md - Documentation
├── hdml-pvc.yaml - PVC configuration for Hyperdisk ML
├── model-downloader.yaml - Job to download model
├── model-snapshot.yaml - VolumeSnapshot configuration
└── vllm-gemma-3-12b-hdml.yaml - vLLM deployment manifest for Gemma 3 12B (Hyperdisk ML)
```

GKE Autopilot과 **Hyperdisk ML**을 사용하여 Gemma-3 모델을 고속으로 서빙하는 과정을 설명합니다. Hyperdisk ML은 모델 가중치 로딩 시간을 획기적으로 단축시켜 빠른 스케일업을 지원합니다.

이 가이드는 **Hyperdisk ML**을 사용하여 모델 로딩 성능(I/O)을 극대화하는 방법을 안내합니다. Hyperdisk ML은 **최대 100GB/s 이상의 처리량**을 제공하며, **ReadOnlyMany** 모드를 지원하여 수천 개의 Pod가 동시에 고속으로 모델을 로드할 수 있도록 지원합니다.

Hyperdisk ML은 블록 스토리지이며 ReadOnlyMany 모드를 지원하지만, 근본적으로 단일 영역에 종속된(Zonal) 리소스이므로, 다른 영역의 노드에서는 접근이 불가능합니다. 따라서 스냅샷을 이용해 새로운 영역에 PV를 복제하는 방법을 사용합니다.



### 1. 기본 환경 설정 (Basic Environment Setup)

먼저, Google Cloud 프로젝트 및 클러스터 관련 환경 변수를 설정합니다.

*   `HUGGINGFACE_TOKEN`: Gemma 모델을 다운로드받기 위한 HuggingFace Access Token입니다.ssssss

```bash
export PROJECT_ID=
export HUGGINGFACE_TOKEN=

export REGION=asia-southeast1
export CLUSTER_NAME=vllm-gemma-3-hdml
```

### 2. GKE Autopilot 클러스터 생성 (Create GKE Autopilot Cluster)

GPU 워크로드를 실행할 GKE Autopilot 클러스터를 생성합니다.

```bash
gcloud container clusters create-auto $CLUSTER_NAME  --auto-monitoring-scope=ALL --region $REGION
gcloud container clusters get-credentials $CLUSTER_NAME --region $REGION
```

### 3. HuggingFace Token으로 Secret 생성 (Create Secret with HuggingFace Token)

vLLM 서버가 HuggingFace에서 모델을 다운로드할 수 있도록 토큰을 Kubernetes Secret으로 저장합니다.

```bash
kubectl create secret generic hf-secret \
    --from-literal=hf_api_token=${HUGGINGFACE_TOKEN} \
    --dry-run=client -o yaml | kubectl apply -f -
```

### 4. 모델 다운로드 Job 실행 (Run Model Download Job)

**왜 Hyperdisk Balanced를 먼저 사용하나요?**
Hyperdisk ML은 **읽기 전용(Read-Only)** 모드에 특화되어 있어, 데이터를 처음 쓸(Write) 때는 일반적인 R/W 디스크가 필요합니다.
따라서, 먼저 **Hyperdisk Balanced** 볼륨을 생성하여 HuggingFace에서 모델 데이터를 다운로드하고 저장합니다.

*   Autopilot에서는 노드의 Ephemeral Storage가 작을 수 있으므로, 모델 저장을 위해 별도의 Persistent Volume(PV)을 연결하여 Job을 수행합니다.

```bash
kubectl apply -f model-downloader.yaml
```

작업 상태 확인:
```bash
$ kubectl get job
NAME                   STATUS     COMPLETIONS   DURATION   AGE
model-downloader-job   Complete   1/1           5m20s      7m42s
```
`model-downloader-job`이 `Complete` 상태가 될 때까지 대기합니다.

### 5. 볼륨 스냅샷 생성 (Create Volume Snapshot)

**스냅샷의 역할:**
데이터가 저장된 Hyperdisk Balanced 볼륨의 "현재 상태"를 사진 찍듯이 저장합니다. 이 스냅샷은 원본 디스크와 독립적인 객체가 되며, 이를 기반으로 새로운 디스크를 여러 개 찍어낼 수 있습니다.
특히 Hyperdisk ML 볼륨을 생성하기 위해서는 반드시 이 스냅샷이 필요합니다.

```bash
kubectl apply -f model-snapshot.yaml
```

### 6. Hyperdisk ML 스토리지 클래스 및 PVC 생성 (Create StorageClass & PVC for Hyperdisk ML)

이제 스냅샷을 소스로 하여 **Hyperdisk ML** 볼륨을 생성합니다.

**Hyperdisk ML의 핵심 특징:**
1.  **ReadOnlyMany:** 하나의 디스크를 수천 개의 Pod가 동시에 마운트하여 읽을 수 있습니다. (데이터 중복 저장 불필요)
2.  **Multi-Zone 배포:** 원본 디스크는 특정 Zone(예: zone-a)에 종속되지만, 스냅샷을 이용하면 zone-b, zone-c 등 **다른 Zone에서도 동일한 데이터가 담긴 Hyperdisk ML 볼륨을 생성**할 수 있습니다.
3.  **고속 로딩:** 모델 가중치 로딩에 최적화된 처리량을 제공합니다.

아래 명령어로 생성되는 StorageClass는 클러스터가 걸쳐 있는 모든 Zone을 명시하여, 어느 Zone에 Pod가 뜨더라도 로컬 Zone의 Hyperdisk ML에 접근할 수 있도록 합니다.

```bash
kubectl apply -f hdml-pvc.yaml
```

### 7. Inference Server 배포 (Deploy Inference Server)

준비된 Hyperdisk ML 볼륨을 마운트하여 vLLM 서버를 배포합니다. 모델 파일이 이미 고속 스토리지에 준비되어 있으므로 서버 시작 시간이 단축됩니다.

```bash
kubectl apply -f vllm-gemma-3-12b-hdml.yaml
```

```
(VllmWorker rank=0 pid=164) INFO 11-19 18:27:44 [cuda.py:290] Using Flash Attention backend on V1 engine.
Loading safetensors checkpoint shards:   0% Completed | 0/5 [00:00<?, ?it/s]
Loading safetensors checkpoint shards:  20% Completed | 1/5 [00:02<00:09,  2.26s/it]
Loading safetensors checkpoint shards:  40% Completed | 2/5 [00:04<00:07,  2.35s/it]
Loading safetensors checkpoint shards:  60% Completed | 3/5 [00:07<00:04,  2.40s/it]
Loading safetensors checkpoint shards:  80% Completed | 4/5 [00:09<00:02,  2.39s/it]
Loading safetensors checkpoint shards: 100% Completed | 5/5 [00:11<00:00,  2.38s/it]
Loading safetensors checkpoint shards: 100% Completed | 5/5 [00:11<00:00,  2.37s/it]
(VllmWorker rank=0 pid=164) 
(VllmWorker rank=0 pid=164) INFO 11-19 18:27:57 [default_loader.py:262] Loading weights took 11.92 seconds
(VllmWorker rank=1 pid=165) INFO 11-19 18:27:57 [default_loader.py:262] Loading weights took 11.98 seconds
(VllmWorker rank=0 pid=164) INFO 11-19 18:27:57 [gpu_model_runner.py:1892] Model loading took 11.9642 GiB and 13.051931 seconds
(VllmWorker rank=1 pid=165) INFO 11-19 18:27:57 [gpu_model_runner.py:1892] Model loading took 11.9642 GiB and 13.095882 seconds
```

a 와 b zone 에 모두 
```
$ kubectl get no
NAME                                               STATUS   ROLES    AGE   VERSION
gk3-vllm-gemma-3-hdml-nap-1fqdiium-553c57f1-sj2l   Ready    <none>   11m   v1.33.5-gke.1201000
gk3-vllm-gemma-3-hdml-nap-1fqdiium-b8e05fe5-n6d5   Ready    <none>   10m   v1.33.5-gke.1201000

$ kubectl describe no | grep 'topology.kubernetes.io/zone'
                    topology.kubernetes.io/zone=asia-southeast1-a
                    topology.kubernetes.io/zone=asia-southeast1-b
```
### 8. 테스트 (Test)

배포된 모델이 정상적으로 작동하는지 테스트합니다.

#### 8.1. 서비스 IP 설정 (Set Service IP)

```bash
export VLLM_SERVICE=$(kubectl get service vllm-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
```

#### 8.2. 추론 요청 (Inference Request)

```bash
curl http://$VLLM_SERVICE/v1/chat/completions \
-X POST \
-H "Content-Type: application/json" \
-d '{
    "model": "/data/gemma-3-12b-it",
    "messages": [
        {
          "role": "user",
          "content": "Why is the sky blue?"
        }
    ]
}' | jq .
```

#### 8.3. 응답 예시 (Example Response)

```json
{
  "id": "chatcmpl-e50322f3b7ef408d90a383525c8a37e6",
  "object": "chat.completion",
  "created": 1763088085,
  "model": "/data/gemma-3-12b-it",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "Okay, let's break down why the sky is blue! ..."
      },
      "finish_reason": "stop"
    }
  ]
}
```