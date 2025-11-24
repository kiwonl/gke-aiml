# Serving Qwen2 with GKE and GPU + TPU fungibility

```
. 
├── ccc.yaml - Custom Compute Class (CCC) configuration for GKE
├── gpu-image/ - Directory for GPU vLLM image build
│   ├── Dockerfile - Dockerfile to build vLLM image for GPU
│   └── gpu_entrypoint.sh - Entrypoint script for GPU vLLM container
├── tpu-image/ - Directory for TPU vLLM image build
│   ├── Dockerfile - Dockerfile to build vLLM image for TPU
│   └── tpu-entrypoint.sh - Entrypoint script for TPU vLLM container
├── README.md - Documentation for TPU & GPU fungibility with vLLM
└── vllm-qwen-2-fungibility.yaml - Kubernetes manifest for deploying Qwen2 with GPU/TPU fungibility
```

https://gke-ai-labs.dev/docs/tutorials/gpu-tpu/fungibility-recipes/
---

## Overview

이 사용자 가이드는 GKE(Google Kubernetes Engine)를 구성하여 TPU 및 GPU에 걸쳐 워크로드를 동적으로 확장하는 방법을 보여줌으로써 AI 추론을 최적화하는 방법을 보여줍니다. 이는 수요 변동 및 용량 제어를 더 잘 관리하는 데 도움이 됩니다. 이 예시에서는 고성능 TPU 노드의 우선 순위를 지정하여 애플리케이션에 최적의 속도와 응답성을 제공하는 동시에 필요에 따라 추가 TPU 및 GPU 노드를 사용하여 최대 수요 시에도 지속적인 서비스를 보장하는 방법을 보여줍니다.

GKE는 Custom Compute Class (CCC)를 통해 GPU + TPU 융통성을 지원하며, 호환 가능한 LLM 모델을 이러한 가속기에서 동시에 대규모로 서비스할 수 있도록 합니다.

[주의] Custom Compute Class 를 정의할 때, 1st - TPU, 2nd/3rd - GPU 이렇게 정의하면 다음과 같은 오류 발생
***Violations details: {"[denied by custom-compute-class-limitation]":["When using TPU config all rules need to have TPU or Nodepools config. ComputeClass 'vllm-fallback'."]}***
즉, TPU 다음 순위로는 TPU or nodePool 만 정의 가능하기 떄문에 GPU 정의 시 오류 발생
이 의미는 결국 nodepool 기반으로 해야 하고, GKE Autopilot 에서는 지원되지 않음을 의미함

---

### 1. 기본 환경 설정 (Basic Environment Setup)

먼저, Google Cloud 프로젝트 및 클러스터 관련 환경 변수를 설정합니다.
*   `HUGGINGFACE_TOKEN`: Gemma 모델을 다운로드받기 위한 HuggingFace Access Token입니다. (모델 사용 권한 승인 필요)

```bash
export PROJECT_ID=

# https://docs.cloud.google.com/tpu/docs/regions-zones#asia-pacific 를 참고하여 TPU 가 지원하는 Region 과 Zone 을 선택
export REGION=asia-northeast1
export ZONE=asia-northeast1-b

export CLUSTER_NAME=tpu-gpu-fungibility
export COMPUTE_CLASS=vllm-fallback

export HUGGINGFACE_TOKEN=
```

### 2. Standard GKE 클러스터 생성 (Create Standard GKE Cluster)

Standard GKE Cluster 를 생성하고, TPU v6e-1, L4, L4 Spot 노드풀을 생성합니다. 그리고 Custom Compute Class 에 따라 우선순위로 정의된 노드풀에 워크로드를 배치하도록 구성합니다.

Standard Cluster 의 Manual Nodepool 에는 다음을 참고해서 Label 과 Taint 를 정의해야 합니다.

[GKE Standard node pools and ComputeClasses](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/about-custom-compute-classes#gke-standard-pools-compute-classes)


```bash
gcloud container clusters create $CLUSTER_NAME \
  --location=$REGION \
  --project=$PROJECT_ID \
  --workload-pool=$PROJECT_ID.svc.id.goog \
  --num-nodes=1 \
  --enable-managed-prometheus \
  --enable-image-streaming \
  --auto-monitoring-scope=ALL
```

Create a TPU v6e-1 node pool
```bash
gcloud container node-pools create v6e-1 \
  --cluster=$CLUSTER_NAME \
  --location=$REGION \
  --node-locations=$ZONE \
  --num-nodes=1 \
  --min-nodes=1 \
  --max-nodes=2 \
  --enable-autoscaling \
  --machine-type=ct6e-standard-1t \
  --node-labels=cloud.google.com/compute-class=$COMPUTE_CLASS \
  --node-taints=cloud.google.com/compute-class=$COMPUTE_CLASS:NoSchedule \
  --async
```

Create a GPU L4 Spot node pool
```bash
gcloud container node-pools create l4-spot \
  --cluster=$CLUSTER_NAME \
  --location=$REGION \
  --node-locations=$ZONE \
  --num-nodes=1 \
  --min-nodes=0 \
  --max-nodes=2 \
  --enable-autoscaling \
  --machine-type "g2-standard-4" \
  --accelerator "type=nvidia-l4,gpu-driver-version=LATEST" \
  --node-labels=cloud.google.com/compute-class=$COMPUTE_CLASS \
  --node-taints=cloud.google.com/compute-class=$COMPUTE_CLASS:NoSchedule \
  --preemptible \
  --async
```

Create a GPU L4 node pool
```bash
gcloud container node-pools create l4 \
  --cluster=$CLUSTER_NAME \
  --location=$REGION \
  --node-locations=$ZONE \
  --num-nodes=1 \
  --machine-type "g2-standard-4" \
  --accelerator "type=nvidia-l4,gpu-driver-version=LATEST" \
  --node-labels=cloud.google.com/compute-class=$COMPUTE_CLASS \
  --node-taints=cloud.google.com/compute-class=$COMPUTE_CLASS:NoSchedule \
  --enable-autoscaling \
  --min-nodes=1 \
  --max-nodes=2 \
  --async
```

### 3. HuggingFace Token으로 Secret 생성 (Create Secret with HuggingFace Token)
```bash
kubectl create secret generic hf-secret \
    --from-literal=hf_api_token=${HUGGINGFACE_TOKEN} \
    --dry-run=client -o yaml | kubectl apply -f -
```

### 4. Custom Compute Class 설정 (Setup Custom Compute Class)
다음 `ccc.yaml`을 생성합니다. 여기서는 노드 풀의 우선 순위(v6e-1이 먼저 확장되고, l4-spot이 두 번째, l4가 마지막으로 확장됨)를 정의합니다.

```bash
cat <<EOF | kubectl apply -f -
apiVersion: cloud.google.com/v1
kind: ComputeClass
metadata:
  name: vllm-fallback
spec:
  priorities:
  - nodepools: [v6e-1]
  - nodepools: [l4-spot]
  - nodepools: [l4]
EOF
```

### 5. vLLM Fungibility 이미지 빌드 (Build the vLLM Fungibility images)
머신에 TPU가 있는지 확인한 다음 vLLM 서버를 시작하는 bash 스크립트가 필요합니다. 머신에 TPU가 있으면 TPU 컨테이너가 서버를 시작하고 GPU 컨테이너는 대기하며, 그 반대도 마찬가지입니다.

GPU 이미지와 TPU 이미지를 저장하기 위한 Artifact Registry 의 Docker-repo 생성
```bash
gcloud artifacts repositories create docker-repo \
    --repository-format=docker \
    --location=${REGION}
```

TPU 이미지 빌드
```bash
cd ~/gke-aiml/serving/07-tpu-gpu-fungibility/tpu-image
gcloud builds submit -t $REGION-docker.pkg.dev/$PROJECT_ID/docker-repo/vllm-fungibility:TPU
```

GPU 이미지 빌드
```bash
cd ~/gke-aiml/serving/07-tpu-gpu-fungibility/gpu-image
gcloud builds submit -t $REGION-docker.pkg.dev/$PROJECT_ID/docker-repo/vllm-fungibility:GPU
```

### 6. vLLM 서버 배포 (Deploy the vLLM Server)
`vllm-qwen-2-fungibility.yaml`을 생성합니다. `$REGION_NAME` 및 `$PROJECT_ID`에 대한 값을 바꿉니다. 미리 빌드된 vLLM 이미지를 사용하려면 이전 섹션의 마지막 단계를 참조하십시오.

> **주의:** `vllm-qwen-2-fungibility.yaml` 파일 내의 `${REGION}`과 `${PROJECT_ID}`를 실제 값으로 변경해야 합니다.
> ```bash
> sed -i "s/\\\$REGION/${REGION}/g" vllm-qwen-2-fungibility.yaml
> sed -i "s/\\\$PROJECT_ID/${PROJECT_ID}/g" vllm-qwen-2-fungibility.yaml
> ```

매니페스트를 다음 명령으로 적용합니다.
```bash
kubectl apply -f vllm-qwen-2-fungibility.yaml
```


<details>
<summary>배치 결과 확인</summary>

```
$ kubectl get no
NAME                                                 STATUS   ROLES    AGE   VERSION
gke-tpu-cfe31df8-k14f                                Ready    <none>   72m   v1.33.5-gke.1201000
gke-tpu-gpu-fungibility-default-pool-5c3b2a26-g3sq   Ready    <none>   74m   v1.33.5-gke.1201000
gke-tpu-gpu-fungibility-default-pool-68fcdea0-psl1   Ready    <none>   74m   v1.33.5-gke.1201000
gke-tpu-gpu-fungibility-default-pool-88bc9778-n9dn   Ready    <none>   75m   v1.33.5-gke.1201000


$ kubectl get po -o=wide
NAME                    READY   STATUS    RESTARTS   AGE     IP          NODE                    NOMINATED NODE   READINESS GATES
vllm-555ccb9b48-pd7fq   2/2     Running   0          5m28s   10.84.4.4   gke-tpu-cfe31df8-k14f   <none>           <none>

$ kubectl describe no gke-tpu-cfe31df8-k14f | grep node.kubernetes.io/instance-type
                    node.kubernetes.io/instance-type=ct6e-standard-1t

$ kubectl logs pod/vllm-555ccb9b48-pd7fq vllm-gpu
machine doesn't contain GPU machines, shutting down container

$ kubectl logs pod/vllm-555ccb9b48-pd7fq vllm-tpu
INFO 11-24 12:39:13 api_server.py:625] vLLM API server version 0.6.4.post2.dev309+g2e33fe41
~~~~~~~~~~~~
INFO 11-24 12:44:50 launcher.py:19] Available routes are:
INFO 11-24 12:44:50 launcher.py:27] Route: /openapi.json, Methods: GET, HEAD
INFO 11-24 12:44:50 launcher.py:27] Route: /docs, Methods: GET, HEAD
INFO 11-24 12:44:50 launcher.py:27] Route: /docs/oauth2-redirect, Methods: GET, HEAD
INFO 11-24 12:44:50 launcher.py:27] Route: /redoc, Methods: GET, HEAD
INFO 11-24 12:44:50 launcher.py:27] Route: /health, Methods: GET
INFO 11-24 12:44:50 launcher.py:27] Route: /tokenize, Methods: POST
INFO 11-24 12:44:50 launcher.py:27] Route: /detokenize, Methods: POST
INFO 11-24 12:44:50 launcher.py:27] Route: /v1/models, Methods: GET
INFO 11-24 12:44:50 launcher.py:27] Route: /version, Methods: GET
INFO 11-24 12:44:50 launcher.py:27] Route: /v1/chat/completions, Methods: POST
INFO 11-24 12:44:50 launcher.py:27] Route: /v1/completions, Methods: POST
INFO 11-24 12:44:50 launcher.py:27] Route: /v1/embeddings, Methods: POST
INFO 11-24 12:44:50 launcher.py:27] Route: /v1/score, Methods: POST
INFO:     Started server process [7]
INFO:     Waiting for application startup.
INFO:     Application startup complete.
INFO:     Uvicorn running on http://0.0.0.0:8000 (Press CTRL+C to quit)

```
</details>

### 7. 테스트 (Test)

배포된 모델이 정상적으로 작동하는지 테스트합니다.

#### 7.1. 서비스 IP 설정 (Set Service IP)

```bash
export VLLM_SERVICE=$(kubectl get service vllm-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
```

#### 7.2. 추론 요청 (Inference Request)

```bash
curl http://$VLLM_SERVICE/v1/chat/completions \
-X POST \
-H "Content-Type: application/json" \
-d '{
    "model": "Qwen/Qwen2-1.5B",
    "messages": [
        {
          "role": "user",
          "content": "Why is the sky blue?"
        }
    ]
}' | jq .
```

#### 7.3. 응답 예시 (Example Response)

```json
{
  "id": "chatcmpl-e50322f3b7ef408d90a383525c8a37e6",
  "object": "chat.completion",
  "created": 1763088085,
  "model": "Qwen/Qwen2-1.5B",
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

#### 8. Replicas 확장
```
kubectl scale deploy/vllm --replicas 3
```

```
$ kubectl get po
NAME                    READY   STATUS    RESTARTS   AGE
vllm-555ccb9b48-pd7fq   2/2     Running   0          15m

$ kubectl get deploy
NAME   READY   UP-TO-DATE   AVAILABLE   AGE
vllm   1/1     1            1           15m

$ kubectl scale deploy/vllm --replicas 3
deployment.apps/vllm scaled

$ kubectl get po -o=wide
NAME                    READY   STATUS    RESTARTS   AGE   IP          NODE                                            NOMINATED NODE   READINESS GATES
vllm-555ccb9b48-nqb58   2/2     Running   0          11m   10.84.5.4   gke-tpu-gpu-fungibility-l4-spot-55a0278b-qdj6   <none>           <none>
vllm-555ccb9b48-pd7fq   2/2     Running   0          27m   10.84.4.4   gke-tpu-cfe31df8-k14f                           <none>           <none>
vllm-555ccb9b48-swlmb   2/2     Running   0          11m   10.84.3.4   gke-tpu-cfe31df8-rc2f                           <none>           <none>

$ kubectl get no
NAME                                                 STATUS   ROLES    AGE     VERSION
gke-tpu-cfe31df8-k14f                                Ready    <none>   94m     v1.33.5-gke.1201000
gke-tpu-cfe31df8-rc2f                                Ready    <none>   10m     v1.33.5-gke.1201000
gke-tpu-gpu-fungibility-default-pool-5c3b2a26-g3sq   Ready    <none>   97m     v1.33.5-gke.1201000
gke-tpu-gpu-fungibility-default-pool-68fcdea0-psl1   Ready    <none>   97m     v1.33.5-gke.1201000
gke-tpu-gpu-fungibility-default-pool-88bc9778-n9dn   Ready    <none>   97m     v1.33.5-gke.1201000
gke-tpu-gpu-fungibility-l4-spot-55a0278b-qdj6        Ready    <none>   9m52s   v1.33.5-gke.1201000

# TPU 노드 
$ kubectl describe no gke-tpu-cfe31df8-rc2f | grep node.kubernetes.io/instance-type
                    node.kubernetes.io/instance-type=ct6e-standard-1t

# GPU 노드 (Spot)
$ kubectl describe no gke-tpu-gpu-fungibility-l4-spot-55a0278b-qdj6 | grep node.kubernetes.io/instance-type
                    node.kubernetes.io/instance-type=g2-standard-4
```

```
$ kubectl describe no gke-tpu-cfe31df8-rc2f
Name:               gke-tpu-cfe31df8-rc2f
Labels:             beta.kubernetes.io/arch=amd64
                    beta.kubernetes.io/instance-type=ct6e-standard-1t
                    beta.kubernetes.io/os=linux
                    cloud.google.com/compute-class=vllm-fallback
                    cloud.google.com/gke-accelerator-count=1
                    cloud.google.com/gke-boot-disk=hyperdisk-balanced
                    cloud.google.com/gke-container-runtime=containerd
                    cloud.google.com/gke-cpu-scaling-level=44
                    cloud.google.com/gke-logging-variant=DEFAULT
                    cloud.google.com/gke-max-pods-per-node=110
                    cloud.google.com/gke-memory-gb-scaling-level=180
                    cloud.google.com/gke-netd-ready=true
                    cloud.google.com/gke-nodepool=v6e-1
                    cloud.google.com/gke-os-distribution=cos
                    cloud.google.com/gke-provisioning=standard
                    cloud.google.com/gke-stack-type=IPV4
                    cloud.google.com/gke-tpu-accelerator=tpu-v6e-slice
                    cloud.google.com/gke-tpu-topology=1x1
                    cloud.google.com/machine-family=ct6e
                    cloud.google.com/private-node=false
                    failure-domain.beta.kubernetes.io/region=asia-northeast1
                    failure-domain.beta.kubernetes.io/zone=asia-northeast1-b
                    iam.gke.io/gke-metadata-server-enabled=true
                    kubernetes.io/arch=amd64
                    kubernetes.io/hostname=gke-tpu-cfe31df8-rc2f
                    kubernetes.io/os=linux
                    node.kubernetes.io/instance-type=ct6e-standard-1t
                    topology.gke.io/zone=asia-northeast1-b
                    topology.kubernetes.io/region=asia-northeast1
                    topology.kubernetes.io/zone=asia-northeast1-b
CreationTimestamp:  Mon, 24 Nov 2025 12:52:45 +0000
+ Taints:             cloud.google.com/compute-class=vllm-fallback:NoSchedule
+                    google.com/tpu=present:NoSchedule

$ kubectl describe no gke-tpu-gpu-fungibility-l4-spot-55a0278b-qdj6
Name:               gke-tpu-gpu-fungibility-l4-spot-55a0278b-qdj6
Labels:             beta.kubernetes.io/arch=amd64
                    beta.kubernetes.io/instance-type=g2-standard-4
                    beta.kubernetes.io/os=linux
                    cloud.google.com/compute-class=vllm-fallback
                    cloud.google.com/gke-accelerator=nvidia-l4
                    cloud.google.com/gke-boot-disk=pd-balanced
                    cloud.google.com/gke-container-runtime=containerd
                    cloud.google.com/gke-cpu-scaling-level=4
                    cloud.google.com/gke-gpu=true
                    cloud.google.com/gke-gpu-driver-version=latest
                    cloud.google.com/gke-logging-variant=DEFAULT
                    cloud.google.com/gke-max-pods-per-node=110
                    cloud.google.com/gke-memory-gb-scaling-level=16
                    cloud.google.com/gke-netd-ready=true
                    cloud.google.com/gke-nodepool=l4-spot
                    cloud.google.com/gke-os-distribution=cos
                    cloud.google.com/gke-preemptible=true
                    cloud.google.com/gke-provisioning=preemptible
                    cloud.google.com/gke-stack-type=IPV4
                    cloud.google.com/machine-family=g2
                    cloud.google.com/private-node=false
                    failure-domain.beta.kubernetes.io/region=asia-northeast1
                    failure-domain.beta.kubernetes.io/zone=asia-northeast1-b
                    iam.gke.io/gke-metadata-server-enabled=true
                    kubernetes.io/arch=amd64
                    kubernetes.io/hostname=gke-tpu-gpu-fungibility-l4-spot-55a0278b-qdj6
                    kubernetes.io/os=linux
                    node.kubernetes.io/instance-type=g2-standard-4
                    topology.gke.io/zone=asia-northeast1-b
                    topology.kubernetes.io/region=asia-northeast1
                    topology.kubernetes.io/zone=asia-northeast1-b
CreationTimestamp:  Mon, 24 Nov 2025 12:53:23 +0000
+ Taints:             cloud.google.com/compute-class=vllm-fallback:NoSchedule
+                    nvidia.com/gpu=present:NoSchedule
```