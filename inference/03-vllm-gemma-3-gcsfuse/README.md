# AI Model Serving with GCS Fuse

GCS Fuse를 사용하여 Google Cloud Storage(GCS) 버킷을 로컬 파일 시스템처럼 마운트하고, 대용량 모델을 효율적으로 로드하여 서빙하는 방법입니다.

### 1. 환경 설정 (Environment Setup)

먼저, Google Cloud 프로젝트 및 클러스터 관련 환경 변수를 설정합니다.
*   `HUGGINGFACE_TOKEN`: Gemma 모델을 다운로드받기 위한 HuggingFace Access Token입니다. (모델 사용 권한 승인 필요)
```bash
export PROJECT_ID=
export PROJECT_NUMBER=

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

GKE Pod가 GCS 버킷에 접근할 수 있도록 IAM 권한과 Kubernetes ServiceAccount를 연결합니다.

```bash
# Kubernetes ServiceAccount 생성
kubectl create serviceaccount gpu-k8s-sa

# Google Service Account (GSA) 생성
gcloud iam service-accounts create gke-ai-sa

# GSA에 GCS 권한 부여
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member "serviceAccount:gke-ai-sa@$PROJECT_ID.iam.gserviceaccount.com" \
    --role roles/storage.objectUser

gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member "serviceAccount:gke-ai-sa@$PROJECT_ID.iam.gserviceaccount.com" \
    --role roles/storage.insightsCollectorService

# Workload Identity 바인딩 (KSA와 GSA 연결)
gcloud iam service-accounts add-iam-policy-binding gke-ai-sa@$PROJECT_ID.iam.gserviceaccount.com \
    --role roles/iam.workloadIdentityUser \
    --member "serviceAccount:$PROJECT_ID.svc.id.goog[default/gpu-k8s-sa]"

# KSA에 GSA 주석 추가
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

GCS 버킷을 영구 볼륨(Persistent Volume)으로 사용하기 위해 설정을 적용합니다. [관련 문서](https://cloud.google.com/kubernetes-engine/docs/how-to/cloud-storage-fuse-csi-driver-perf#inference-serving-example)

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
kubectl apply -f vllm-gemma-3-12b.yaml
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