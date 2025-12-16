# Serving Llama 3 on GKE with vLLM and Inference Gateway

```
. 
├── README.md - Documentation
├── vllm-gemma-3-4b-ccc.yaml - vLLM deployment manifest for Gemma 3 4B (Custom Compute Class)
├── vllm-gemma-3-4b.yaml - vLLM deployment manifest for Gemma 3 4B
├── vllm-gemma-3-12b.yaml - vLLM deployment manifest for Gemma 3 12B
└── vllm-gemma-3-27b.yaml - vLLM deployment manifest for Gemma 3 27B
```
---
이 문서는 GKE Autopilot 환경에서 vLLM을 사용하여 Llama 3 모델을 서빙하고, Inference Gateway를 통해 효율적으로 트래픽을 관리하는 방법을 안내합니다. Inference Gateway를 사용하면 여러 모델에 대한 단일 진입점을 제공하고 정교한 트래픽 라우팅 및 우선순위 제어가 가능합니다.

관련 문서:
- [GKE Inference Gateway Documentation](https://cloud.google.com/kubernetes-engine/docs/how-to/deploy-gke-inference-gateway)


## Serve the Llama 3 model on vLLM with Inference Gateway

GKE Autopilot에서 Llama 3 모델을 배포하고 Inference Gateway를 구성하는 단계별 절차입니다.

### 1. 기본 환경 설정 (Basic Environment Setup)

먼저, Google Cloud 프로젝트 ID, 리전, 클러스터 이름 등의 환경 변수를 설정합니다. `HUGGINGFACE_TOKEN`은 Llama 3 모델 다운로드를 위해 필요합니다.

```bash
export PROJECT_ID= 

export REGION=asia-southeast1
export CLUSTER_NAME=vllm-gemma-3-igw
```
```bash
export HUGGINGFACE_TOKEN=
```

### 2. GKE Autopilot 클러스터 생성 (Create GKE Autopilot Cluster)

GPU 워크로드를 실행할 수 있는 GKE Autopilot 클러스터를 생성합니다. `--auto-monitoring-scope=ALL` 옵션을 사용하여 vLLM 애플리케이션 메트릭을 자동으로 수집하도록 설정합니다.

```bash
gcloud container clusters create-auto $CLUSTER_NAME --auto-monitoring-scope=ALL --region $REGION
gcloud container clusters get-credentials $CLUSTER_NAME --region $REGION
```

### 3. HuggingFace Token으로 Secret 생성 (Create Secret with HuggingFace Token)

vLLM Pod가 시작될 때 HuggingFace에서 모델을 다운로드할 수 있도록 토큰을 Kubernetes Secret으로 생성합니다.

```bash
kubectl create secret generic hf-token \
    --from-literal=token=${HUGGINGFACE_TOKEN} \
    --dry-run=client -o yaml | kubectl apply -f -
```

### 4. Inference Server 배포 (Deploy Inference Server)

Llama-3.1-8B 모델을 서빙하는 vLLM Deployment와 Service를 배포합니다.

```bash
kubectl apply -f ./gpu-deployment.yaml
```

배포된 Pod와 ConfigMap 상태를 확인합니다.

```bash
$ kubectl get po, cm
NAME                                       READY   STATUS    RESTARTS   AGE
vllm-llama3-8b-instruct-84f98d5766-9fq8s   2/2     Running   0          19m
vllm-llama3-8b-instruct-84f98d5766-vr29b   2/2     Running   0          19m
vllm-llama3-8b-instruct-84f98d5766-xczc6   2/2     Running   0          19m

NAME                                         DATA   AGE
configmap/vllm-llama3-8b-instruct-adapters   1      24m

$ kubectl describe po vllm-llama3-8b-instruct-84f98d5766-9fq8s
~~~~~~~~~~~~~~~~~
Init Containers:
  lora-adapter-syncer:
    Container ID:   containerd://24736b13a3e7d5ab0a137d91e2caf38980bf0c70bd9ddcd6c955980b48869781
    Image:          registry.k8s.io/gateway-api-inference-extension/lora-syncer:v1.0.2
    Image ID:       registry.k8s.io/gateway-api-inference-extension/lora-syncer@sha256:b3a84b55d7ff57020ef5ec9ea62e1fc1420236a6ae754da3543afe4820cde7b3
~~~~~~~~~~~~~~~~~
Containers:
  vllm:
    Container ID:  containerd://74672b9d57ddcfbdfef1742d96bb713c55a92c17bce1624fff78449d53c0ed3e
    Image:         vllm/vllm-openai:v0.8.5
    Image ID:      docker.io/vllm/vllm-openai@sha256:6cf9808ca8810fc6c3fd0451c2e7784fb224590d81f7db338e7eaf3c02a33d33
~~~~~~~~~~~~~~~~~
```

### 5. InferenceObject CRD 설치

Gateway API 확장을 위한 InferenceObject Custom Resource Definition(CRD)을 설치합니다.

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/raw/v1.0.0/config/crd/bases/inference.networking.x-k8s.io_inferenceobjectives.yaml
```

### 6. InferencePool 설치 (by Helm)

Helm을 사용하여 InferencePool을 설치합니다. 이는 추론 서버들을 그룹화하고 관리하는 리소스입니다.

```bash
helm install vllm-llama3-8b-instruct \
  --set inferencePool.modelServers.matchLabels.app=vllm-llama3-8b-instruct \
  --set provider.name=gke \
  --set inferenceExtension.monitoring.gke.enabled=true \
  --version v1.0.1 \
  --set provider.gke.autopilot=true \
  oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool
```

설치 결과를 확인합니다.

```bash
$ helm install vllm-llama3-8b-instruct \
  --set inferencePool.modelServers.matchLabels.app=vllm-llama3-8b-instruct \
  --set provider.name=gke \
  --set inferenceExtension.monitoring.gke.enabled=true \
  --version v1.0.1 \
  --set provider.gke.autopilot=true \
  oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool
Pulled: registry.k8s.io/gateway-api-inference-extension/charts/inferencepool:v1.0.1
Digest: sha256:301b913dbff1d75017db0962b621e6780777dcb658475df60d1c6b5b84ee1635
I1216 08:05:06.983747    6531 warnings.go:110] "Warning: autopilot-default-resources-mutator:Autopilot updated Deployment default/vllm-llama3-8b-instruct-epp: defaulted unspecified 'cpu' resource for containers [epp] (see http://g.co/gke/autopilot-defaults)."
NAME: vllm-llama3-8b-instruct
LAST DEPLOYED: Tue Dec 16 08:05:03 2025
NAMESPACE: default
STATUS: deployed
REVISION: 1
TEST SUITE: None
NOTES:
InferencePool vllm-llama3-8b-instruct deployed.

$ kubectl get inferencepool
NAME                      AGE
vllm-llama3-8b-instruct   28s

$ kubectl get inferencepool vllm-llama3-8b-instruct -o yaml
apiVersion: inference.networking.k8s.io/v1
kind: InferencePool
metadata:
  annotations:
    meta.helm.sh/release-name: vllm-llama3-8b-instruct
    meta.helm.sh/release-namespace: default
  creationTimestamp: "2025-12-16T08:05:07Z"
  generation: 1
  labels:
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/name: vllm-llama3-8b-instruct-epp
    app.kubernetes.io/version: v1.0.1
  name: vllm-llama3-8b-instruct
  namespace: default
  resourceVersion: "1765872307182687020"
  uid: 055c659f-292e-424b-be68-86f9f156edef
spec:
  endpointPickerRef:
    failureMode: FailClose
    group: ""
    kind: Service
    name: vllm-llama3-8b-instruct-epp
    port:
      number: 9002
  selector:
    matchLabels:
      app: vllm-llama3-8b-instruct
  targetPorts:
  - number: 8000
```

### 7. InferenceObjective 정의 (Define InferenceObjective)

각기 다른 트래픽 유형에 대해 우선순위를 지정하기 위해 InferenceObjective를 정의합니다.

``` bash
cat <<EOF | kubectl apply -f - 
apiVersion: inference.networking.x-k8s.io/v1alpha2
kind: InferenceObjective
metadata:
  name: food-review
spec:
  priority: 10
  poolRef:
    name: vllm-llama3-8b-instruct
    group: "inference.networking.k8s.io"
---
apiVersion: inference.networking.x-k8s.io/v1alpha2
kind: InferenceObjective
metadata:
  name: llama3-base-model
spec:
  priority: 20 # Higher priority 
  poolRef:
    name: vllm-llama3-8b-instruct
EOF
```

### 8. Gateway 및 HTTPRoute 정의 (Define Gateway and HTTPRoute)

Inference Gateway를 생성하기 위한 사전 작업으로 Network Service API를 활성화하고 프록시 전용 서브넷을 구성합니다.

#### 8.1. Network Service API 활성화

```bash
gcloud services enable networkservices.googleapis.com
```

#### 8.2. 프록시 전용 서브넷 구성 (Internal LB Only)

```bash
gcloud compute networks subnets create proxy-only-sb \
    --purpose=REGIONAL_MANAGED_PROXY \
    --role=ACTIVE \
    --region=us-central1 \
    --network=default \
    --range=172.20.0.0/23
```

### 9. Inference Gateway 생성

준비된 Gateway 및 HTTPRoute 매니페스트를 적용하여 실제 게이트웨이를 생성합니다.

```bash
kubectl apply -f inference-gw.yaml 
```

### 10. 테스트 (Test)

클라이언트 VM을 생성하고, 게이트웨이를 통해 모델에 추론 요청을 보내 테스트를 수행합니다.

#### 10.1. 클라이언트 VM 생성

```bash

gcloud compute instances create client --zone us-central1-c --subnet default
gcloud compute ssh client --zone=us-central1-c
```

#### 10.2. 추론 요청 (VM 내부에서 실행)

```bash

# Gateway IP 확인
IP=$(kubectl get gateway/inference-gateway -o jsonpath='{.status.addresses[0].address}')
PORT=80
```

**요청 1: Llama-3 Base Model 요청 예시**
```bash
$ curl -i -X POST ${IP}:${PORT}/v1/completions \
-H 'Content-Type: application/json' \
-H 'Authorization: Bearer $(gcloud auth application-default print-access-token)' \
-d 
'{
    "model": "meta-llama/Llama-3.1-8B-Instruct",
    "prompt": "Why is the sky blue?",
    "max_tokens": 2048,
    "temperature": "0"
}'
HTTP/1.1 200 OK
x-went-into-resp-headers: true
date: Tue, 16 Dec 2025 08:42:15 GMT
server: uvicorn
content-type: application/json
via: 1.1 google
transfer-encoding: chunked

{"choices":[{"finish_reason":"stop","index":0,"logprobs":null,"prompt_logprobs":null,"stop_reason":128001,"text": " It's a question that has puzzled humans for centuries. The answer, however, is quite simple. The sky appears blue because of a phenomenon called Rayleigh scattering, named after the British physicist Lord Rayleigh, who first described it in the late 19th century.\nRayleigh scattering occurs when sunlight enters Earth's atmosphere and encounters tiny molecules of gases such as nitrogen and oxygen. These molecules scatter the light in all directions, but they scatter shorter (blue) wavelengths more than longer (red) wavelengths. This is because the smaller molecules are more effective at scattering the smaller, faster-moving blue light particles.\nAs a result, the blue light is distributed throughout the atmosphere, giving the sky its blue appearance. The exact shade of blue can vary depending on atmospheric conditions, such as pollution and dust particles, which can scatter light in different ways and affect the color of the sky.\nIn addition to Rayleigh scattering, other factors can influence the color of the sky, such as the time of day, the amount of cloud cover, and the presence of aerosols in the atmosphere. However, the basic principle of Rayleigh scattering remains the same, and it is the primary reason why the sky appears blue to our eyes.\nSo, the next time you gaze up at a blue sky, remember the tiny molecules of gases in the atmosphere that are scattering the light and making it look so beautiful! #RayleighScattering #BlueSky #Science #Atmosphere\nThe post Why is the sky blue? appeared first on The Daily Telescope. ."}],"created":1765874535,"id":"cmpl-e5ac466e-e316-47e3-aa89-80396edce8e4","model":"meta-llama/Llama-3.1-8B-Instruct","object":"text_completion","usage":{"completion_tokens":309,"prompt_tokens":7,"prompt_tokens_details":null,"total_tokens":316}}
```

**요청 2: LoRA Adapter 요청 예시**
```bash
$ curl -i -X POST ${IP}:${PORT}/v1/completions -H 'Content-Type: application/json' -H 'Authorization: Bearer $(gcloud auth print-access-token)' -d 
'{
    "model": "food-review-1",
    "prompt": "What is the best pizza in the world?",
    "max_tokens": 2048,
    "temperature": "0"
}'
HTTP/1.1 200 OK
x-went-into-resp-headers: true
date: Tue, 16 Dec 2025 08:42:02 GMT
server: uvicorn
content-type: application/json
via: 1.1 google
transfer-encoding: chunked

{"choices":[{"finish_reason":"stop","index":0,"logprobs":null,"prompt_logprobs":null,"stop_reason":null,"text": " This is a question that has sparked debate among foodies for centuries. While opinions may vary, here are some of the most popular pizza styles that are worth trying:\n\n1. **Neapolitan Pizza**: This classic Italian style is known for its soft crust, fresh toppings, and rich flavors. Try it with San Marzano tomatoes, mozzarella cheese, and basil for an authentic experience.\n\n2. **Roman Pizza**: This style is characterized by a crispy crust and a light coating of sauce. It often features toppings like prosciutto, arugula, and burrata cheese.\n\n3. **New York-Style Pizza**: Known for its large, thin slices, this style is perfect for those who enjoy a classic American pizza. Try it with pepperoni, mushrooms, and extra cheese.\n\n4. **California Pizza**: This style is known for its non-traditional toppings and flavors. Try it with pineapple, BBQ chicken, and avocado for a unique twist.\n\n5. **Sicilian Pizza**: This thick-crusted pizza is perfect for those who enjoy a hearty meal. Try it with anchovies, eggplant, and ricotta cheese for a flavorful experience.\n\nRemember, the best pizza is always the one that you enjoy the most, so feel free to experiment with different toppings and styles to find your perfect pie!"}],"created":1765874522,"id":"cmpl-cf384d3c-021d-4574-9014-9934e39d8bac","model":"food-review-1","object":"text_completion","usage":{"completion_tokens":268,"prompt_tokens":10,"prompt_tokens_details":null,"total_tokens":278}}
```
