# AI Model Serving with Secondary Boot Disks and Hyperdisk ML

## Secondary Boot Disk Image Creation

보조 부팅 디스크(Secondary Boot Disk)를 사용하여 모델 데이터를 미리 로드한 이미지를 생성하는 과정입니다. [관련 문서](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/data-container-image-preloading#prepare)

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

Google Cloud에서 제공하는 디스크 이미지 빌더 도구를 다운로드합니다.

```bash
git clone https://github.com/ai-on-gke/tools.git
cd tools/gke-disk-image-builder
```

### 3. 로그 저장용 GCS 버킷 생성 (Create GCS Bucket for Logs)

빌드 로그를 저장할 GCS 버킷을 생성합니다.

```bash
gsutil mb -b on -l $REGION gs://$LOG_BUCKET_NAME
```

### 4. Go 의존성 정리 (Tidy Go Dependencies)

```bash
go mod tidy
```

### 5. Secondary Boot Disk 이미지 생성 (Create Image)

빌더를 실행하여 컨테이너 이미지가 포함된 디스크 이미지를 생성합니다. 이 작업은 수 분이 소요될 수 있습니다.

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
```
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

GKE가 프로젝트의 커스텀 이미지를 사용할 수 있도록 `GCPResourceAllowlist`를 생성합니다. Autopilot 모드에서는 이 단계가 필수적입니다.

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
sed -i "s/\$VLLM_DISK_IMAGE_NAME/${VLLM_DISK_IMAGE_NAME}/g" vllm-gemma-3-4b.yaml
sed -i "s/\$PROJECT_ID/${PROJECT_ID}/g" vllm-gemma-3-4b.yaml
```

```bash
kubectl apply -f vllm-gemma-3-4b.yaml
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

### 7. 반복 테스트 (Repetitive Test)

```bash
for i in {1..10}; do
  echo "Request #$i"
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
    }'
  echo ""  # Newline
  sleep 1
done
```
