# Serving Gemma 3 on GKE with vLLM and GPU

```
.
├── README.md - Documentation
├── vllm-gemma-3-4b-ccc.yaml - vLLM deployment manifest for Gemma 3 4B (Custom Compute Class)
├── vllm-gemma-3-4b.yaml - vLLM deployment manifest for Gemma 3 4B
├── vllm-gemma-3-12b.yaml - vLLM deployment manifest for Gemma 3 12B
└── vllm-gemma-3-27b.yaml - vLLM deployment manifest for Gemma 3 27B
```
---
이 가이드는 GKE Autopilot에서 vLLM을 사용하여 Gemma-3 모델을 서빙하는 방법을 안내합니다. 또한, GMP(Google Managed Prometheus) 로 수집한 vLLM 의 메트릭을 사용해 HPA(Horizontal Pod Autoscaler)를 적용한 Pod Autoscaling 구성도 포함되어 있습니다.

- [Serve Gemma open models using GPUs on GKE with vLLM](https://cloud.google.com/kubernetes-engine/docs/tutorials/serve-gemma-gpu-vllm)

- [Best practices for autoscaling large language model (LLM) inference workloads with GPUs on Google Kubernetes Engine (GKE)](https://cloud.google.com/kubernetes-engine/docs/best-practices/machine-learning/inference/autoscaling)


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

GPU 워크로드를 실행할 GKE Autopilot 클러스터를 생성합니다.


* `--auto-monitoring-scope=ALL`:**
  *   이 옵션은 워크로드, 특히 vLLM 의 메트릭을 자동 수집하고 대시보드를 자동으로 구축힙니다. (vLLM과 같은 AI 추론 서버는 CPU/Memory 사용량뿐만 아니라 `num_requests_waiting`(대기 큐 길이), `gpu_cache_usage`(KV 캐시 사용량) 등 애플리케이션 레벨의 메트릭이 중요)

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

일반적인 웹 서버는 CPU 사용량을 기준으로 스케일링하지만, LLM 추론 서버는 GPU가 병목이 되거나 요청 큐가 쌓이는 것이 더 중요한 지표입니다. 여기서는 **"대기 중인 요청 수(`num_requests_waiting`)"**를 기준으로 오토스케일링을 구성합니다.

### 1. vLLM 메트릭을 GMP로 수집하기 위한 Pod Monitoring 정의 (Define Pod Monitoring for vLLM Metrics to GMP)

`PodMonitoring`은 GMP(Google Managed Prometheus)만의 커스텀 리소스(CR)입니다. 기존의 복잡한 Prometheus 설정 파일(configmap)을 수정할 필요 없이, 이 리소스를 배포하는 것만으로 특정 Pod의 메트릭을 수집하도록 지시할 수 있습니다.

*   **역할:** `app: gemma-server` 라벨이 붙은 Pod를 찾아 `8000` 포트의 `/metrics` 경로를 15초마다 스크랩(Scrape)합니다.

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

설정이 적용되면 Cloud Monitoring에 데이터가 쌓이기 시작합니다.

*   **확인 방법:** Google Cloud Console > Monitoring > Metrics Explorer
*   **주요 메트릭:** `vllm:num_requests_waiting` (현재 처리되지 못하고 큐에서 대기 중인 사용자 요청 수)
*   이 값이 0보다 크다는 것은 현재 GPU 용량이 포화 상태임을 의미하므로, 스케일 아웃(Pod 추가)이 필요하다는 신호입니다.

```bash
# Cloud Console에서 확인 필요
vllm:num_requests_waiting{cluster='CLUSTER_NAME_HERE'}
```

### 3. Custom Metrics Stackdriver Adapter 설치 (Install Custom Metrics Stackdriver Adapter)

Kubernetes의 HPA 컨트롤러는 기본적으로 CPU/Memory 메트릭만 이해합니다. 우리가 수집한 `vllm:num_requests_waiting`과 같은 외부(Custom) 메트릭을 HPA가 이해할 수 있도록 변환해주는 **어댑터(Adapter)**가 필요합니다.

*   **작동 원리:** HPA -> Adapter -> Cloud Monitoring API 순서로 데이터를 조회하여 스케일링 여부를 결정합니다.

```bash
# Workload Identity 권한 부여 (어댑터가 Cloud Monitoring API를 읽을 수 있도록 권한 할당)
gcloud projects add-iam-policy-binding projects/$PROJECT_ID \
  --role roles/monitoring.viewer \
  --member=principal://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/$PROJECT_ID.svc.id.goog/subject/ns/custom-metrics/sa/custom-metrics-stackdriver-adapter
```
```bash
# 어댑터 설치
kubectl apply -f https://raw.githubusercontent.com/GoogleCloudPlatform/k8s-stackdriver/master/custom-metrics-stackdriver-adapter/deploy/production/adapter_new_resource_model.yaml
```

### 4. HPA 적용 (Apply HPA)

이제 HPA 규칙을 정의합니다.

*   **목표(`target`):** `averageValue: 10`
*   **의미:** "모든 Pod의 평균 대기 요청 수가 10개를 넘어가면 Pod를 추가하라."
*   사용자가 느끼는 지연 시간(Latency)을 관리하기 위해 이 임계값을 조정할 수 있습니다.

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

Github Sample Codes: https://github.com/GoogleCloudPlatform/kubernetes-engine-samples/tree/main/ai-ml/llm-serving-gemma/vllm
