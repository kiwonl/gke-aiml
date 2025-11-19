# AI Model Inference

Github Sample Codes: https://github.com/GoogleCloudPlatform/kubernetes-engine-samples/tree/main/ai-ml/llm-serving-gemma/vllm

## Serve the Gemma-3 model on vLLM (Autopilot)

GKE Autopilot을 사용하여 Gemma-3 모델을 vLLM으로 서빙하는 과정을 설명합니다.

### 1. 기본 환경 설정 (Basic Environment Setup)

먼저, Google Cloud 프로젝트 및 클러스터 관련 환경 변수를 설정합니다.
*   `HUGGINGFACE_TOKEN`: Gemma 모델을 다운로드받기 위한 HuggingFace Access Token입니다. (모델 사용 권한 승인 필요)
```bash
export PROJECT_ID=
export PROJECT_NUMBER=

export REGION=asia-southeast1
export CLUSTER_NAME=vllm-gemma-3
```
```bash
export HUGGINGFACE_TOKEN=
```

### 2. GKE Autopilot 클러스터 생성 (Create GKE Autopilot Cluster)

GPU 워크로드를 실행할 GKE Autopilot 클러스터를 생성합니다. Autopilot 모드는 노드 관리를 자동화하여 운영 편의성을 높여줍니다.

*   [`--auto-monitoring-scope=ALL`](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/configure-automatic-application-monitoring): 워크로드, 특히 vllm 에 대한 매트릭 모니터링을 자동으로 구성(메트릭 수집, 대시보드 제공 등)합니다.

```bash
gcloud container clusters create-auto $CLUSTER_NAME --auto-monitoring-scope=ALL --region $REGION
gcloud container clusters get-credentials $CLUSTER_NAME --region $REGION
```

### 3. HuggingFace Token으로 Secret 생성 (Create Secret with HuggingFace Token)

vLLM 서버가 HuggingFace에서 모델을 다운로드할 수 있도록 토큰을 Kubernetes Secret으로 저장합니다.

```bash
kubectl create secret generic hf-secret \
    --from-literal=hf_api_token=${HUGGINGFACE_TOKEN} \
    --dry-run=client -o yaml | kubectl apply -f -
```

### 4. Inference Server 배포 (Deploy Inference Server - AI nomdel from HuggingFace)

Gemma-3 4B 모델을 서빙하는 vLLM Pod를 배포합니다. 이 매니페스트는 Deployment와 Service를 포함하고 있으며, HuggingFace에서 직접 모델을 다운로드하여 실행합니다.

```bash
kubectl apply -f vllm-gemma-3-4b.yaml
```

> **참고:** 필요에 따라 [Custom Compute Class](./vllm-gemma-3-4b-ccc.yaml)를 사용 하여 특정 GPU 타입이나 리소스를 명시적으로 정의할 수도 있습니다.

### 5. 테스트 (Test)

배포된 모델이 정상적으로 작동하는지 테스트합니다.

#### 5.1. 서비스 IP 설정 (Set Service IP)

LoadBalancer 타입으로 생성된 서비스의 외부 IP 주소를 가져옵니다.

```bash
export VLLM_SERVICE=$(kubectl get service vllm-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
```

#### 5.2. 추론 요청 (Inference Request)

curl 명령어를 사용하여 채팅 완성을 요청합니다.

```bash
curl http://$VLLM_SERVICE/v1/chat/completions \
-X POST \
-H "Content-Type: application/json" \
-d '{
    "model": "google/gemma-3-4b-it",
    "messages": [
        {
          "role": "user",
          "content": "Why is the sky blue?"
        }
    ]
}' | jq .
```

#### 5.3. 응답 예시 (Example Response)

정상적인 응답은 다음과 같은 JSON 형식을 가집니다.

```json
{
  "id": "chatcmpl-e50322f3b7ef408d90a383525c8a37e6",
  "object": "chat.completion",
  "created": 1763088085,
  "model": "google/gemma-3-4b-it",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "Okay, let's break down why the sky is blue! ..."
      },
      "finish_reason": "stop"
    }
  ],
  ...
}
```

#### 5.4. 반복 테스트 (Repetitive Test)

서비스 안정성을 확인하기 위해 10번 반복해서 요청을 보냅니다.

```bash
for i in {1..10}; do
  echo "Request #$i"
    curl http://$VLLM_SERVICE/v1/chat/completions \
    -X POST \
    -H "Content-Type: application/json" \
    -d '{
        "model": "google/gemma-3-4b-it",
        "messages": [
            {
              "role": "user",
              "content": "Why is the sky blue?"
            }
        ]
    }' 
  echo ""  # 응답 구분을 위한 줄바꿈
done
```

---

## HPA를 위해 vLLM 메트릭을 GMP로 수집 (Collect vLLM Metrics to GMP for HPA)

Horizontal Pod Autoscaler (HPA)가 vLLM의 메트릭(예: 대기 중인 요청 수)을 기반으로 Pod를 자동 확장하도록 설정합니다. 이를 위해 Google Managed Prometheus (GMP)를 사용합니다.

### 1. vLLM 메트릭을 GMP로 수집하기 위한 Pod Monitoring 정의 (Define Pod Monitoring for vLLM Metrics to GMP)

GMP가 vLLM 파드의 `/metrics` 엔드포인트에서 데이터를 스크랩하도록 `PodMonitoring` 리소스를 생성합니다.

*   [참고 문서](https://cloud.google.com/kubernetes-engine/docs/tutorials/serve-vllm-tpu#create-load:~:text=following%20manifest%20as-,vllm_pod_monitor.yaml,-%3A)

```bash
cat <<EOF | kubectl apply -f -
apiVersion: monitoring.googleapis.com/v1
kind: PodMonitoring
metadata:
  name: vllm-pod-monitoring
spec:
  selector:
    matchLabels:
      app: gemma-server
  endpoints:
  - port: 8000
    path: "/metrics" # default value
    interval: 15s
EOF
```

### 2. vLLM 메트릭 수집 확인 (Verify vLLM Metrics in GMP)

Cloud Console의 Monitoring > Metric Explorer에서 메트릭이 수집되고 있는지 확인합니다.

*   쿼리 예시: `vllm:num_requests_waiting`
*   [참고 문서](https://cloud.google.com/kubernetes-engine/docs/tutorials/serve-vllm-tpu#verify-prometheus)

```bash
# Cloud Console에서 확인 필요
vllm:num_requests_waiting{cluster='CLUSTER_NAME_HERE'}
```

### 3. Custom Metrics Stackdriver Adapter 설치 (Install Custom Metrics Stackdriver Adapter)

HPA가 Cloud Monitoring(Stackdriver)의 메트릭을 읽을 수 있도록 어댑터를 설치하고 권한을 부여합니다.

*   [참고 문서](https://cloud.google.com/kubernetes-engine/docs/tutorials/serve-vllm-tpu#set-up-ca)

```bash
# Workload Identity 권한 부여
gcloud projects add-iam-policy-binding projects/$PROJECT_ID \
  --role roles/monitoring.viewer \
  --member=principal://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/$PROJECT_ID.svc.id.goog/subject/ns/custom-metrics/sa/custom-metrics-stackdriver-adapter
```
```bash
# 어댑터 설치
kubectl apply -f https://raw.githubusercontent.com/GoogleCloudPlatform/k8s-stackdriver/master/custom-metrics-stackdriver-adapter/deploy/production/adapter_new_resource_model.yaml
```

### 4. HPA 적용 (Apply HPA)

`num_requests_waiting`(대기 중인 요청 수) 메트릭을 기준으로 Pod를 자동으로 확장하는 HPA를 배포합니다. 대기 요청이 평균 10개를 넘으면 Pod 수가 증가합니다.

*   [참고 문서](https://cloud.google.com/kubernetes-engine/docs/tutorials/serve-vllm-tpu#deploy-hpa)

```bash
kubectl apply -f - <<EOF
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
 name: vllm-hpa
spec:
 scaleTargetRef:
   apiVersion: apps/v1
   kind: Deployment
   name: vllm-gemma-deployment
 minReplicas: 1
 maxReplicas: 2
 metrics:
   - type: Pods
     pods:
       metric:
         name: prometheus.googleapis.com|vllm:num_requests_waiting|gauge
       target:
         type: AverageValue
         averageValue: 10
EOF
```

### 5. 부하 테스트 (Load Test)

HPA가 정상적으로 작동하는지 확인하기 위해 인위적으로 부하를 발생시킵니다.

#### 5.1. `load_test.sh` 스크립트 생성 (Create `load_test.sh` script)

여러 개의 백그라운드 프로세스로 동시에 요청을 보내는 스크립트를 생성합니다.

```bash
cat << 'EOF' > load_test.sh
#!/bin/bash
N=5
for i in {1..10}; do
  while true; do
    curl http://$VLLM_SERVICE/v1/chat/completions \
    -X POST \
    -H "Content-Type: application/json" \
    -d '{
        "model": "google/gemma-3-4b-it",
        "messages": [
            {
              "role": "user",
              "content": "Why is the sky blue?"
            }
        ]
    }' 
  done &  # Run in the background
done
wait
EOF
```

```bash
# HPA 상태 모니터링 (TARGETS 값이 증가하고 REPLICAS가 늘어나는지 확인)
kubectl get hpa -w
```


#### 5.2. 부하 테스트 실행 및 확인 (Run Load Test & Verify)

스크립트를 실행하여 부하를 주고, HPA가 이를 감지하여 스케일링을 수행하는지 확인합니다.

```bash
# 실행 권한 부여
chmod a+x load_test.sh

# 백그라운드 실행
nohup ./load_test.sh &

# 요청 동작 확인
tail -f nohup.out
```

```
NAME       REFERENCE                          TARGETS   MINPODS   MAXPODS   REPLICAS   AGE
vllm-hpa   Deployment/vllm-gemma-deployment   12/10     1         2         1          3m18s
---
NAME       REFERENCE                          TARGETS   MINPODS   MAXPODS   REPLICAS   AGE
vllm-hpa   Deployment/vllm-gemma-deployment   12/10     1         2         2          3m42s

$ kubectl get po
NAME                                     READY   STATUS    RESTARTS   AGE
vllm-gemma-deployment-769db55d6f-fs5lw   1/1     Running   0          3m3s
vllm-gemma-deployment-769db55d6f-x29m7   1/1     Running   0          27m
```


#### 5.3. 테스트 종료 (Cleanup)

테스트가 끝나면 부하 생성 프로세스를 종료합니다.

```bash
pkill -f load_test.sh
```