# Serving Gemma 3 on GKE with vLLM, GPU and Secondary Boot Disk

```
.
├── README.md - Documentation
└── vllm-gemma-3-4b-sbd.yaml - vLLM deployment manifest for Gemma 3 4B (Secondary Boot Disk)
```
---

이 가이드는 **Secondary Boot Disk**를 활용하여 대용량 컨테이너 이미지를 미리 로드(Pre-load)하고, 이를 통해 AI 추론 워크로드의 **초기 구동 시간(Cold Start)을 획기적으로 단축**하는 방법을 다룹니다.

[Use secondary boot disks to preload data or container images](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/data-container-image-preloading)


## Secondary Boot Disk Image Creation

일반적인 GKE 배포에서 Pod가 시작될 때 컨테이너 이미지를 네트워크를 통해 레지스트리에서 다운로드(Pull)합니다. AI 모델 이미지는 수 GB에서 수십 GB에 달하므로 이 과정에서 수 분의 지연 시간이 발생할 수 있습니다.

**해결책:**
컨테이너 이미지가 이미 다운로드된 상태의 디스크(Secondary Boot Disk)를 생성합니다. GKE 노드는 이미지를 다운로드하는 대신, 이 디스크를 로컬 스토리지처럼 즉시 마운트하여 컨테이너를 실행합니다. 이는 **Cold Start 시간을 획기적으로 줄여줍니다.**

### 1. 환경 설정 (Environment Setup)

이미지 빌드에 필요한 환경 변수를 설정합니다.

```bash
export PROJECT_ID=
export REGION=asia-southeast1
export ZONE=${REGION}-a

export LOG_BUCKET_NAME=$PROJECT_ID-logs
export VLLM_DISK_IMAGE_NAME=vllm-image
```

### 2. Secondary Boot Disk Builder 다운로드 (Download Builder)

Google Cloud에서 제공하는 [GKE Disk Image Builder](https://github.com/ai-on-gke/tools) 도구를 사용합니다. 이 도구는 복잡한 VM 생성 및 이미지 생성 과정을 자동화해 줍니다.

```bash
git clone https://github.com/ai-on-gke/tools.git
cd tools/gke-disk-image-builder
```

### 3. 로그 저장용 GCS 버킷 생성 (Create GCS Bucket for Logs)

Disk Imgage Builder가 실행되는 동안 발생하는 로그를 저장할 공간입니다.

```bash
gsutil mb -b on -l $REGION gs://$LOG_BUCKET_NAME
```

### 4. Go 의존성 정리 (Tidy Go Dependencies)

```bash
go mod tidy
```

### 5. Secondary Boot Disk 이미지 생성 (Create Image)

빌더를 실행하면 내부적으로 다음 작업이 수행됩니다.
1.  임시 VM 인스턴스 생성.
2.  지정된 컨테이너 이미지(`vllm/vllm-openai:v0.10.0`)를 `docker pull`로 다운로드.
3.  이미지가 저장된 데이터 디스크를 분리(Detach)하여 GCE Disk Image(`vllm-image`)로 저장.
4.  임시 VM 삭제. (빌더에서 생성한 리소스를 자동으로 정리)

```bash
go run ./cli \
--project-name=$PROJECT_ID \
--image-name=$VLLM_DISK_IMAGE_NAME \
--zone=$ZONE \
--gcs-path=gs://$LOG_BUCKET_NAME \
--disk-size-gb=100 \
--container-image=docker.io/vllm/vllm-openai:v0.10.0
```

<details>
<summary>실행 결과 예시 (Execution Result Example)</summary>

```
[secondary-disk-image]: 2025-11-19T07:09:10Z Validating workflow
[secondary-disk-image]: 2025-11-19T07:09:10Z Validating step "create-disk"
[secondary-disk-image]: 2025-11-19T07:09:10Z Validating step "create-instance"
[secondary-disk-image]: 2025-11-19T07:09:12Z Validating step "wait-on-image-creation"
[secondary-disk-image]: 2025-11-19T07:09:12Z Validating step "detach-disk"
[secondary-disk-image]: 2025-11-19T07:09:12Z Validating step "create-image"
[secondary-disk-image]: 2025-11-19T07:09:12Z Validation Complete
[secondary-disk-image]: 2025-11-19T07:09:12Z Workflow Project: qwiklabs-asl-01-cb385fd8bcca
[secondary-disk-image]: 2025-11-19T07:09:12Z Workflow Zone: asia-southeast1-a
[secondary-disk-image]: 2025-11-19T07:09:12Z Workflow GCSPath: gs://qwiklabs-asl-01-cb385fd8bcca-logs
[secondary-disk-image]: 2025-11-19T07:09:12Z Daisy scratch path: https://console.cloud.google.com/storage/browser/qwiklabs-asl-01-cb385fd8bcca-logs/daisy-secondary-disk-image-20251119-07:09:10-m3ng6
[secondary-disk-image]: 2025-11-19T07:09:12Z Uploading sources
[secondary-disk-image]: 2025-11-19T07:09:13Z Running workflow
[secondary-disk-image]: 2025-11-19T07:09:13Z Running step "create-disk" (CreateDisks)
[secondary-disk-image.create-disk]: 2025-11-19T07:09:13Z CreateDisks: Creating disk "secondary-disk-image-disk".
[secondary-disk-image]: 2025-11-19T07:09:15Z Step "create-disk" (CreateDisks) successfully finished.
[secondary-disk-image]: 2025-11-19T07:09:15Z Running step "create-instance" (CreateInstances)
[secondary-disk-image.create-instance]: 2025-11-19T07:09:15Z CreateInstances: Creating instance "secondary-disk-image-instance".
[secondary-disk-image]: 2025-11-19T07:10:05Z Step "create-instance" (CreateInstances) successfully finished.
[secondary-disk-image]: 2025-11-19T07:10:05Z Running step "wait-on-image-creation" (WaitForInstancesSignal)
[secondary-disk-image.create-instance]: 2025-11-19T07:10:05Z CreateInstances: Streaming instance "secondary-disk-image-instance" serial port 1 output to https://storage.cloud.google.com/qwiklabs-asl-01-cb385fd8bcca-logs/daisy-secondary-disk-image-20251119-07:09:10-m3ng6/logs/secondary-disk-image-instance-serial-port1.log
[secondary-disk-image.wait-on-image-creation]: 2025-11-19T07:10:05Z WaitForInstancesSignal: Instance "secondary-disk-image-instance": watching serial port 1, SuccessMatch: "Unpacking is completed", FailureMatch: ["startup-script-url exit status 1" "Failed to pull and unpack the image"] (this is not an error).
[secondary-disk-image.wait-on-image-creation]: 2025-11-19T07:17:26Z WaitForInstancesSignal: Instance "secondary-disk-image-instance": SuccessMatch found "Unpacking is completed."
[secondary-disk-image]: 2025-11-19T07:17:26Z Step "wait-on-image-creation" (WaitForInstancesSignal) successfully finished.
[secondary-disk-image]: 2025-11-19T07:17:26Z Running step "detach-disk" (DetachDisks)
[secondary-disk-image.detach-disk]: 2025-11-19T07:17:26Z DetachDisks: Detaching disk "secondary-disk-image-disk" from instance "secondary-disk-image-instance".
[secondary-disk-image]: 2025-11-19T07:17:29Z Step "detach-disk" (DetachDisks) successfully finished.
[secondary-disk-image]: 2025-11-19T07:17:29Z Running step "create-image" (CreateImages)
[secondary-disk-image.create-image]: 2025-11-19T07:17:29Z CreateImages: Creating image "vllm-image".
[secondary-disk-image]: 2025-11-19T07:19:44Z Step "create-image" (CreateImages) successfully finished.
[secondary-disk-image]: 2025-11-19T07:19:44Z Workflow "secondary-disk-image" cleaning up (this may take up to 2 minutes).
[secondary-disk-image]: 2025-11-19T07:20:34Z Workflow "secondary-disk-image" finished cleanup.
Image has successfully been created at: projects/qwiklabs-asl-01-cb385fd8bcca/global/images/vllm-image
```
</details>

---

## AI Model Serving with Secondary Boot Disk

생성된 보조 부팅 디스크 이미지를 사용하여 빠른 시작 시간을 보장하는 AI 모델 서빙을 구성합니다.

### 1. 환경 설정 (Environment Setup)

```bash
export PROJECT_ID=
export HUGGINGFACE_TOKEN=
```
```bash
export CLUSTER_NAME=vllm-gemma-3-secondarybd
```

### 2. GKE Autopilot 클러스터 생성 (Create GKE Autopilot Cluster)

Secondary Boot Disk를 사용하기 위한 설정은 Standrad 와 Autopilot 이 다르기 때문에 다음을 확인합니다.
*   **GKE Standard**: Image Streaming 활성화 (`--enable-image-streaming`) 및 Node Pool 생성 시 이미지 정보 설정 필요.
*   **GKE Autopilot**: `GCPResourceAllowlist`를 통한 디스크 이미지 허용 및 `nodeSelector` 설정 필요.

```bash
gcloud container clusters create-auto $CLUSTER_NAME --auto-monitoring-scope=ALL --region $REGION
gcloud container clusters get-credentials $CLUSTER_NAME --region $REGION
```

### 3. HuggingFace Token으로 Secret 생성 (Create Secret with HuggingFace Token)

```bash
kubectl create secret generic hf-secret \
    --from-literal=hf_api_token=${HUGGINGFACE_TOKEN} \
    --dry-run=client -o yaml | kubectl apply -f -
```

### 4. 디스크 이미지 허용 정책 설정 (Allow Secondary Boot Disk Image)

**중요 (Autopilot Security):**
GKE Autopilot은 보안을 위해 기본적으로 검증되지 않은 외부 디스크 이미지의 사용을 차단합니다. 우리가 앞서 만든 `vllm-image`는 프로젝트 내의 커스텀 이미지이므로, 이를 클러스터에서 사용할 수 있도록 **명시적으로 허용(Allowlist)** 해주어야 합니다.

*   `GCPResourceAllowlist` 리소스를 통해 특정 프로젝트의 이미지를 신뢰할 수 있는 리소스로 등록합니다.

```bash
kubectl apply -f - <<EOF
apiVersion: "node.gke.io/v1"
kind: GCPResourceAllowlist
metadata:
  name: gke-secondary-boot-disk-allowlist
spec:
  allowedResourcePatterns:
  - "projects/${PROJECT_ID}/global/images/.*"
EOF
```

### 5. Deployment 배포 (Deploy vLLM)

Secondary Boot Disk를 사용하는 Pod를 배포합니다.

```bash
sed -i "s/\$VLLM_DISK_IMAGE_NAME/${VLLM_DISK_IMAGE_NAME}/g" vllm-gemma-3-4b-sbd.yaml
sed -i "s/\$PROJECT_ID/${PROJECT_ID}/g" vllm-gemma-3-4b-sbd.yaml
```

```bash
kubectl apply -f vllm-gemma-3-4b-sbd.yaml
```

### 6. 테스트 (Test)

#### 6.1. 서비스 IP 확인 (Get Service IP)

```bash
export VLLM_SERVICE=$(kubectl get service vllm-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
```

#### 6.2. 추론 요청 (Inference Request)

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

#### 6.3. 응답 예시 (Example Response)

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