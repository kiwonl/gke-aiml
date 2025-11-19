# AI Model Serving with Hyperdisk ML

Github Sample Codes: https://github.com/GoogleCloudPlatform/kubernetes-engine-samples/tree/main/ai-ml/llm-serving-gemma/vllm

## Serve the Gemma-3 model on vLLM with Hyperdisk ML

GKE Autopilot과 **Hyperdisk ML**을 사용하여 Gemma-3 모델을 고속으로 서빙하는 과정을 설명합니다. Hyperdisk ML은 모델 가중치 로딩 시간을 획기적으로 단축시켜 빠른 스케일업을 지원합니다.

### 1. 기본 환경 설정 (Basic Environment Setup)

먼저, Google Cloud 프로젝트 및 클러스터 관련 환경 변수를 설정합니다.

*   `PROJECT_ID`: 현재 작업 중인 Google Cloud 프로젝트 ID입니다.
*   `PROJECT_NUMBER`: 프로젝트 번호입니다.
*   `HUGGINGFACE_TOKEN`: Gemma 모델을 다운로드받기 위한 HuggingFace Access Token입니다.
*   `CLUSTER_NAME`: 생성할 GKE 클러스터의 이름입니다.
*   `REGION`: 클러스터가 배포될 리전입니다.

```bash
export PROJECT_ID=
export PROJECT_NUMBER=
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

HuggingFace에서 모델을 다운로드하여 **Hyperdisk Balanced**에 저장하는 Job을 실행합니다. Hyperdisk ML은 직접 쓰기가 불가능하므로, 먼저 일반 디스크에 다운로드해야 합니다.
[관련 문서](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/persistent-volumes/hyperdisk-ml#populate-disk)

```bash
kubectl apply -f hf-downloader.yaml
```

Job이 완료될 때까지 대기합니다.
```bash
kubectl wait --for=condition=complete job/model-downloader --timeout=300s
```

### 5. 볼륨 스냅샷 생성 (Create Volume Snapshot)

모델이 저장된 Hyperdisk Balanced 볼륨으로부터 **Volume Snapshot**을 생성합니다. 이 스냅샷은 이후 Hyperdisk ML 볼륨을 생성하는 원본으로 사용됩니다.

```bash
kubectl apply -f volume-snapshot.yaml
```

### 6. Hyperdisk ML 스토리지 클래스 및 PVC 생성 (Create StorageClass & PVC for Hyperdisk ML)

생성된 스냅샷을 소스로 하여 **Hyperdisk ML** 타입의 PersistentVolumeClaim (PVC)을 생성합니다. Hyperdisk ML은 읽기 전용이지만 매우 빠른 로딩 속도를 제공합니다.

```bash
kubectl apply -f hdml-pv.yaml
```

### 7. Inference Server 배포 (Deploy Inference Server)

준비된 Hyperdisk ML 볼륨을 마운트하여 vLLM 서버를 배포합니다. 모델 파일이 이미 고속 스토리지에 준비되어 있으므로 서버 시작 시간이 단축됩니다.

```bash
kubectl apply -f vllm-gemma-3-12b.yaml
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
    "model": "google/gemma-3-12b-it",
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
  "model": "google/gemma-3-12b-it",
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