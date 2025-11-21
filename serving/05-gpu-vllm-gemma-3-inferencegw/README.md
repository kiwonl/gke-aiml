# Inference Gateway with vLLM and LoRA Adapters

GKE Inference Gateway를 사용하여 여러 LoRA(Low-Rank Adaptation) 어댑터를 사용하는 모델을 효율적으로 서빙하는 방법입니다. [관련 문서](https://cloud.google.com/kubernetes-engine/docs/tutorials/serve-with-gke-inference-gateway)

### 1. 환경 설정 (Environment Setup)

```bash
export PROJECT_ID=
export HUGGINGFACE_TOKEN=
```

### 2. Model Serving 개요 (Overview)

*   **GKE Inference Quickstart**: [공식 문서](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/machine-learning/inference/inference-quickstart#deploy)를 통해 빠르게 배포 가능합니다.
*   **Self Deployment**: 직접 매니페스트를 작성하여 배포하는 방식입니다. 아래 과정은 이 방식을 따릅니다.

### 3. Inference CRD 설치 (Install Inference CRDs)

Inference Gateway 기능을 사용하기 위해 필요한 Custom Resource Definition(CRD)을 설치합니다. [준비 문서](https://cloud.google.com/kubernetes-engine/docs/how-to/deploy-gke-inference-gateway#prepare-environment)

*   **GKE 버전 1.34.0-gke.1626000+ 이상**: `InferenceObjective` CRD만 설치.
    ```bash
    kubectl apply -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/raw/v1.0.0/config/crd/bases/inference.networking.x-k8s.io_inferenceobjectives.yaml
    ```
*   **이전 버전**: 모든 CRD 설치.
    ```bash
    kubectl apply -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/v1.0.0/manifests.yaml
    ```

### 4. 메트릭 스크래핑 권한 부여 (Grant Permissions for Metrics)

Inference Gateway가 메트릭을 수집할 수 있도록 RBAC 권한을 설정합니다.

```bash
kubectl apply -f - <<EOF
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: inference-gateway-metrics-reader
rules:
- nonResourceURLs:
  - /metrics
  verbs:
  - get
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: inference-gateway-sa-metrics-reader
  namespace: default
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: inference-gateway-sa-metrics-reader-role-binding
  namespace: default
subjects:
- kind: ServiceAccount
  name: inference-gateway-sa-metrics-reader
  namespace: default
roleRef:
  kind: ClusterRole
  name: inference-gateway-metrics-reader
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: v1
kind: Secret
metadata:
  name: inference-gateway-sa-metrics-reader-secret
  namespace: default
  annotations:
    kubernetes.io/service-account.name: inference-gateway-sa-metrics-reader
type: kubernetes.io/service-account-token
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: inference-gateway-sa-metrics-reader-secret-read
rules:
- resources:
  - secrets
  apiGroups: [""]
  verbs: ["get", "list", "watch"]
  resourceNames: ["inference-gateway-sa-metrics-reader-secret"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: gmp-system:collector:inference-gateway-sa-metrics-reader-secret-read
  namespace: default
roleRef:
  name: inference-gateway-sa-metrics-reader-secret-read
  kind: ClusterRole
  apiGroup: rbac.authorization.k8s.io
subjects:
- name: collector
  namespace: gmp-system
  kind: ServiceAccount
EOF
```

### 5. HuggingFace Token으로 Secret 생성 (Create Secret with HuggingFace Token)

```bash
kubectl create secret generic hf-secret \
    --from-literal=hf_api_token=${HUGGINGFACE_TOKEN} \
    --dry-run=client -o yaml | kubectl apply -f - 
```

### 6. 모델 서버 배포 (Deploy Model Server)

Gemma-3 4B 모델과 LoRA 어댑터를 포함하는 vLLM 서버를 배포합니다.

*   Base Model: `google/gemma-3-4b-it`
*   LoRA Adapter 1: `jeongyoonhuh/travel-checker`
*   LoRA Adapter 2: `ohdyo/q_lora_trip_checker`

```bash
kubectl apply -f vllm-gemma-3-4b-lora.yaml
```

Pod 및 Service 상태 확인:
```bash
kubectl get po,svc
```

### 7. InferencePool 생성 (Create InferencePool)

Helm을 사용하여 InferencePool을 생성합니다. 이는 모델 서버 그룹을 관리하고 라우팅을 위한 엔드포인트를 제공합니다.

```bash
helm install vllm-gemma-3-4b-it \
  --set inferencePool.modelServers.matchLabels.app=vllm-gemma-3-4b-lora \
  --set provider.name=gke \
  --version v0.3.0 \
  oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool
```

생성 확인:
```bash
kubectl get inferencepool vllm-gemma-3-4b-it
```

### 8. InferenceModel 정의 (Define InferenceModels)

각 LoRA 어댑터와 기본 모델을 `InferenceModel` 리소스로 정의하여 라우팅 대상을 명확히 합니다. 각 모델의 중요도(`criticality`)를 설정할 수 있습니다.

```bash
cat <<EOF | kubectl apply -f -
# LoRA Adapter (travel-checker)
apiVersion: inference.networking.x-k8s.io/v1alpha2
kind: InferenceModel
metadata:
  name: travel-checker
spec:
  modelName: travel-checker
  criticality: Standard   # Critical, Standard, Sheddable
  poolRef:
    name: vllm-gemma-3-4b-it
---
# LoRA Adapter (trip-checker)
apiVersion: inference.networking.x-k8s.io/v1alpha2
kind: InferenceModel
metadata:
  name: trip-checker
spec:
  modelName: trip-checker
  criticality: Standard
  poolRef:
    name: vllm-gemma-3-4b-it
---
# Base Model (gemma-3-4b-it)
apiVersion: inference.networking.x-k8s.io/v1alpha2
kind: InferenceModel
metadata:
  name: gemma-3-4b-it
spec:
  modelName: gemma-3-4b-it
  criticality: Critical
  poolRef:
    name: vllm-gemma-3-4b-it
EOF
```

### 9. Gateway 및 HTTPRoute 정의 (Define Gateway and HTTPRoute)

네트워크 서비스를 활성화하고 내부 로드 밸런서용 프록시 서브넷을 구성한 후, Gateway 리소스를 생성합니다.

#### 9.1. Network Service API 활성화

```bash
gcloud services enable networkservices.googleapis.com
```

#### 9.2. 프록시 전용 서브넷 구성 (Internal LB Only)

```bash
gcloud compute networks subnets create ilb-proxy \
    --purpose=REGIONAL_MANAGED_PROXY \
    --role=ACTIVE \
    --region=us-central1 \
    --network=default \
    --range=172.20.0.0/23
```

#### 9.3. Gateway 및 Route 생성

```bash
cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: inference-gateway
spec:
  gatewayClassName: gke-l7-rilb # gke-l7-regional-external-managed, gke-l7-rilb
  listeners:
    - protocol: HTTP
      port: 80
      name: http
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: inference-httproute
spec:
  parentRefs:
  - name: inference-gateway
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: "/"
    backendRefs:
    - name: vllm-gemma-3-4b-it
      group: inference.networking.x-k8s.io
      kind: InferencePool
EOF
```

### 10. 테스트 (Test)

동일 리전 내 VM을 생성하여 내부 IP로 접근 테스트를 수행합니다.

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

**모델 1: travel-checker**
```bash
curl -i -X POST ${IP}:${PORT}/v1/completions \
-H 'Content-Type: application/json' \
-H 'Authorization: Bearer $(gcloud auth print-access-token)' \
-d '{
    "model": "travel-checker",
    "prompt": "프랑스 파리에 대해 알려줘. 주요 관광지, 추천 음식, 여행하기 좋은 시기는 언제야?",
    "max_tokens": 2048,
    "temperature": "0"
}'
```

**모델 2: trip-checker**
```bash
curl -i -X POST ${IP}:${PORT}/v1/completions \
-H 'Content-Type: application/json' \
-H 'Authorization: Bearer $(gcloud auth print-access-token)' \
-d '{
    "model": "trip_checker",
    "prompt": "프랑스 파리에 대해 알려줘. 주요 관광지, 추천 음식, 여행하기 좋은 시기는 언제야?",
    "max_tokens": 2048,
    "temperature": "0"
}'
```

**Base Model: gemma-3-4b-it**
```bash
curl -i -X POST ${IP}:${PORT}/v1/completions \
-H 'Content-Type: application/json' \
-H 'Authorization: Bearer $(gcloud auth print-access-token)' \
-d '{
    "prompt": "프랑스 파리에 대해 알려줘. 주요 관광지, 추천 음식, 여행하기 좋은 시기는 언제야?",
    "max_tokens": 2048,
    "temperature": "0"
}'
```
