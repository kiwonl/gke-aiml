# Serving Gemma 3 on GKE with vLLM, GPU and GCSFuse

```
.
├── README.md - Documentation
├── gcs-pvc.yaml - PVC configuration for GCS Fuse
├── model-downloader.yaml - Job to download model
└── vllm-gemma-3-12b-gcsfuse.yaml - vLLM deployment manifest for Gemma 3 12B (GCS Fuse)
```
---
이 가이드는 **GCS Fuse**를 사용하여 Google Cloud Storage(GCS) 버킷을 Kubernetes Pod에 로컬 파일 시스템처럼 마운트하는 방법을 설명합니다. 이 방식은 **모델 관리의 유연성**을 제공하며, 별도의 다운로드 과정 없이 대용량 모델을 즉시 사용할 수 있게 합니다.

GCS Fuse를 사용하여 Google Cloud Storage(GCS) 버킷을 로컬 파일 시스템처럼 마운트하고, 대용량 모델을 효율적으로 로드하여 서빙하는 방법입니다.

### 1. 환경 설정 (Environment Setup)

먼저, Google Cloud 프로젝트 및 클러스터 관련 환경 변수를 설정합니다.
*   `HUGGINGFACE_TOKEN`: Gemma 모델을 다운로드받기 위한 HuggingFace Access Token입니다. (모델 사용 권한 승인 필요)
```bash
export PROJECT_ID=

export REGION=asia-southeast1
export CLUSTER_NAME=vllm-gemma-3-gcsfuse

export BUCKET_NAME=$PROJECT_ID-aimodel
```
```bash
export HUGGINGFACE_TOKEN=
```

### 2. GKE Autopilot 클러스터 생성 (Create GKE Autopilot Cluster)

```bash
gcloud container clusters create-auto $CLUSTER_NAME  --auto-monitoring-scope=ALL --region $REGION
gcloud container clusters get-credentials $CLUSTER_NAME --region $REGION
```

### 3. Workload Identity Federation 설정 (Configure Workload Identity Federation)

보안상 권장되지 않는 "Service Account Key(JSON 파일)"를 다운로드하여 Pod에 마운트하는 대신, **Workload Identity**를 사용하여 안전하게 인증합니다.

*   **작동 원리:** Kubernetes Service Account(KSA)와 Google Service Account(GSA)를 1:1로 연결합니다. Pod가 KSA를 사용하면, GKE가 자동으로 GSA의 권한을 임시 토큰 형태로 발급해줍니다.
*   이 예제에서는 `gpu-k8s-sa`(KSA)가 `gke-ai-sa`(GSA)인 척 하여 GCS 버킷에 접근하게 됩니다.

```bash
# Kubernetes ServiceAccount 생성
kubectl create serviceaccount gpu-k8s-sa

# Google Service Account (GSA) 생성
gcloud iam service-accounts create gke-ai-sa

# GSA에 GCS 권한 부여 (버킷 읽기/쓰기 권한)
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member "serviceAccount:gke-ai-sa@$PROJECT_ID.iam.gserviceaccount.com" \
    --role roles/storage.objectUser

# 메트릭 수집을 위한 권한 추가
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member "serviceAccount:gke-ai-sa@$PROJECT_ID.iam.gserviceaccount.com" \
    --role roles/storage.insightsCollectorService

# Workload Identity 바인딩 (KSA와 GSA 연결)
gcloud iam service-accounts add-iam-policy-binding gke-ai-sa@$PROJECT_ID.iam.gserviceaccount.com \
    --role roles/iam.workloadIdentityUser \
    --member "serviceAccount:$PROJECT_ID.svc.id.goog[default/gpu-k8s-sa]"

# KSA에 GSA 주석 추가 (Pod가 이 KSA를 쓸 때 어떤 GSA로 매핑될지 알려줌)
kubectl annotate serviceaccount gpu-k8s-sa \
    iam.gke.io/gcp-service-account=gke-ai-sa@$PROJECT_ID.iam.gserviceaccount.com
```
KSA 생성 확인
```
$ kubectl get sa
NAME         SECRETS   AGE
default      0         10m
gpu-k8s-sa   0         17s
```

### 4. 모델 저장용 GCS 버킷 생성 (Create GCS Bucket for Model Storage)

```bash
gcloud storage buckets create gs://$BUCKET_NAME --location=$REGION
```

### 5. HuggingFace Token으로 Secret 생성 (Create Secret with HuggingFace Token)

```bash
kubectl create secret generic hf-secret \
    --from-literal=hf_api_token=${HUGGINGFACE_TOKEN} \
    --dry-run=client -o yaml | kubectl apply -f -
```

### 6. GCS Fuse를 이용한 PV, PVC 생성 (Create PV/PVC with GCS Fuse)

GCS 버킷을 Kubernetes의 Persistent Volume(PV)처럼 사용합니다.

*   **GCS Fuse CSI Driver:** Pod가 데이터를 읽으려 할 때, 백그라운드에서 GCS API를 호출하여 데이터를 스트리밍으로 가져옵니다.
*   사용자는 마치 로컬 디스크에 있는 파일을 읽는 것처럼 `/data/model.bin` 경로로 접근하지만, 실제로는 GCS 버킷의 객체를 가져오는 것입니다.
*   **장점:** 모델 사이즈가 아무리 커도 Pod의 로컬 디스크 용량을 차지하지 않으며, 버킷에 파일을 올리면 즉시 모든 Pod에 반영됩니다.

> **주의:** `gcs-pvc.yaml` 파일 내의 `${BUCKET_NAME}`을 실제 버킷 이름으로 변경해야 합니다.
> ```
> sed -i "s/\$BUCKET_NAME/${BUCKET_NAME}/g" gcs-pvc.yaml
> ```


```bash
kubectl apply -f gcs-pvc.yaml
```

### 7. 모델 다운로드 Job 실행 (Run Model Download Job)

HuggingFace에서 모델을 다운로드하여 GCS 버킷(PVC)에 저장하는 Job을 실행합니다. [관련 문서](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/persistent-volumes/hyperdisk-ml#populate-disk)

```bash
kubectl apply -f model-downloader.yaml
```

작업 상태 확인:
```bash
$ kubectl get job
NAME                   STATUS     COMPLETIONS   DURATION   AGE
model-downloader-job   Complete   1/1           2m57s      25m
```
`model-downloader-job`이 `Complete` 상태가 될 때까지 대기합니다.

### 8. Inference Server 배포 (Deploy Inference Server)

모델이 준비되면 vLLM 서버를 배포합니다.

```bash
kubectl apply -f vllm-gemma-3-12b-gcsfuse.yaml
```

### 9. 테스트 (Test)

#### 9.1. 서비스 IP 설정 (Set Service IP)

```bash
export VLLM_SERVICE=$(kubectl get service vllm-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
```

#### 9.2. 추론 요청 (Inference Request)

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

#### 9.3. 응답 예시 (Example Response)

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