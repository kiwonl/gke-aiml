# Serving Gemma 3 on GKE with vLLM, TPU and GCSFuse

```
.
├── README.md - Documentation
└── vllm-gemma-3-12b-tpu.yaml - vLLM deployment manifest for Gemma 3 12B (TPU)
```

## Serve the Gemma-3 model on vLLM (Autopilot)

GKE Autopilot을 사용하여 Gemma-3 모델을 vLLM으로 서빙하는 과정을 설명합니다.

### 1. 기본 환경 설정 (Basic Environment Setup)

먼저, Google Cloud 프로젝트 및 클러스터 관련 환경 변수를 설정합니다.
*   `HUGGINGFACE_TOKEN`: Gemma 모델을 다운로드받기 위한 HuggingFace Access Token입니다. (모델 사용 권한 승인 필요)
```bash
export PROJECT_ID=
export PROJECT_NUMBER=

# https://docs.cloud.google.com/tpu/docs/regions-zones#asia-pacific 를 참고하여 TPU 가 지원하는 Region 과 Zone 을 선택
export REGION=asia-northeast1
export ZONE=asia-northeast1-b

export CLUSTER_NAME=tpu-vllm-gemma-3

export BUCKET_NAME=$PROJECT_ID-aimodel
```
```bash
export HUGGINGFACE_TOKEN=
```

### 2. GKE Autopilot 클러스터 생성 (Create GKE Autopilot Cluster)
[링크](../03-gpu-vllm-gemma-3-gcsfuse/README.md#2-gke-autopilot-클러스터-생성-create-gke-autopilot-cluster)

### 3. Workload Identity Federation 설정 (Configure Workload Identity Federation)
[링크](../03-gpu-vllm-gemma-3-gcsfuse/README.md#3-workload-identity-federation-설정-configure-workload-identity-federation)

### 4. 모델 저장용 GCS 버킷 생성 (Create GCS Bucket for Model Storage)
[링크](../03-gpu-vllm-gemma-3-gcsfuse/README.md#4-모델-저장용-gcs-버킷-생성-create-gcs-bucket-for-model-storage)

### 5. HuggingFace Token으로 Secret 생성 (Create Secret with HuggingFace Token)
[링크](../03-gpu-vllm-gemma-3-gcsfuse/README.md#5-huggingface-token으로-secret-생성-create-secret-with-huggingface-token)

### 6. GCS Fuse를 이용한 PV, PVC 생성 (Create PV/PVC with GCS Fuse)
[링크](../03-gpu-vllm-gemma-3-gcsfuse/README.md#6-gcs-fuse를-이용한-pv-pvc-생성-create-pvpvc-with-gcs-fuse)

### 7. 모델 다운로드 Job 실행 (Run Model Download Job)
[링크](../03-gpu-vllm-gemma-3-gcsfuse/README.md#7-모델-다운로드-job-실행-run-model-download-job)

### 8. Inference Server 배포 (Deploy Inference Server)
모델이 준비되면 vLLM 서버를 배포합니다.

```bash
kubectl apply -f vllm-gemma-3-12b-tpu.yaml
```


<details>
<summary>실행 결과 예시 (Execution Result Example)</summary>

```
$ kubectl get po -o=wide
NAME                                     READY   STATUS    RESTARTS   AGE   IP             NODE                    NOMINATED NODE   READINESS GATES
vllm-gemma-deployment-59dc7974fc-wrpmr   3/3     Running   0          8h    10.77.128.70   gk3-tpu-d0b4136a-w2j9   <none>           <none>

$ kubectl describe no gk3-tpu-d0b4136a-w2j9
Name:               gk3-tpu-d0b4136a-w2j9
Roles:              <none>
Labels:             addon.gke.io/node-local-dns-ds-ready=true
                    beta.kubernetes.io/arch=amd64
                    beta.kubernetes.io/instance-type=ct6e-standard-4t
                    beta.kubernetes.io/os=linux
+                    cloud.google.com/gke-accelerator-count=4
                    cloud.google.com/gke-boot-disk=hyperdisk-balanced
                    cloud.google.com/gke-container-runtime=containerd
                    cloud.google.com/gke-cpu-scaling-level=180
+                    cloud.google.com/gke-gcfs=true
                    cloud.google.com/gke-image-streaming=true
                    cloud.google.com/gke-logging-variant=DEFAULT
                    cloud.google.com/gke-max-pods-per-node=32
                    cloud.google.com/gke-memory-gb-scaling-level=737
                    cloud.google.com/gke-netd-ready=true
                    cloud.google.com/gke-nodepool=nap-1roqiaf4
                    cloud.google.com/gke-os-distribution=cos
                    cloud.google.com/gke-provisioning=standard
                    cloud.google.com/gke-stack-type=IPV4
+                    cloud.google.com/gke-tpu-accelerator=tpu-v6e-slice
+                    cloud.google.com/gke-tpu-topology=2x2
                    cloud.google.com/machine-family=ct6e
                    cloud.google.com/private-node=false
                    cloud.google.com/slice-of-hardware=true
                    failure-domain.beta.kubernetes.io/region=asia-northeast1
                    failure-domain.beta.kubernetes.io/zone=asia-northeast1-b
                    iam.gke.io/gke-metadata-server-enabled=true
                    kubernetes.io/arch=amd64
                    kubernetes.io/hostname=gk3-tpu-d0b4136a-w2j9
                    kubernetes.io/os=linux
+                    node.kubernetes.io/instance-type=ct6e-standard-4t
                    node.kubernetes.io/masq-agent-ds-ready=true
+                    topology.gke.io/zone=asia-northeast1-b
                    topology.kubernetes.io/region=asia-northeast1
                    topology.kubernetes.io/zone=asia-northeast1-b
```
</details>


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