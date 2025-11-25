# GKE AI/ML 활용 가이드 (GKE AI/ML Serving Guide)

이 저장소는 **Google Kubernetes Engine (GKE)** 환경에서 최신 AI/ML 워크로드를 효율적으로 구축, 배포 및 운영하기 위한 포괄적인 가이드를 제공합니다.

Google의 최신 개방형 모델인 **Gemma 3**와 고성능 추론 엔진 **vLLM**을 중심으로, **GPU** 및 **TPU** 가속기를 활용한 다양한 서빙 시나리오를 다룹니다. 또한, 스토리지 최적화, 오토스케일링, 멀티 모델 서빙 등 프로덕션 수준의 운영을 위한 모범 사례(Best Practices)를 포함하고 있습니다.

## 🚀 주요 특징 (Key Features)

*   **최신 모델 및 엔진**: Gemma 3 (4B, 12B, 27B) 및 vLLM 기반의 최적화된 추론 서빙.
*   **다양한 하드웨어 지원**: NVIDIA GPU (L4, A100) 및 Google Cloud TPU (v6e) 활용.
*   **GKE 모드**: GKE Autopilot을 기본으로 하며, 고급 구성을 위한 GKE Standard 예제 포함.
*   **스토리지 최적화**: GCS Fuse, Hyperdisk ML, Secondary Boot Disk를 통한 모델 로딩 속도 및 관리 효율성 증대.
*   **고급 트래픽 관리**: Inference Gateway를 활용한 LoRA 어댑터 기반 멀티 모델 라우팅.
*   **유연성 및 비용 최적화**: GPU와 TPU 간의 유연한 자원 할당(Fungibility) 및 Spot 인스턴스 활용.

## 📂 예제 목록 (AI Model Serving Scenarios)

각 디렉토리는 독립적인 시나리오를 담고 있으며, 상세한 가이드와 매니페스트 파일(`yaml`)을 포함합니다.

| # | 예제 (바로가기) | 주요 기술 및 특징 | Accelerate | GKE Mode |
| :--- | :--- | :--- | :--- | :--- |
| 01 | **[Basic vLLM & Gemma 3](./serving/01-gpu-vllm-gemma-3/)** | • **기본 배포**: vLLM을 이용한 Gemma 3 서빙<br>• **HPA**: GMP(Google Managed Prometheus) 기반의 커스텀 메트릭 오토스케일링 | GPU | Autopilot |
| 02 | **[Secondary Boot Disk](./serving/02-gpu-vllm-gemma-3-secondarybd/)** | • **콜드 스타트 해결**: 컨테이너 이미지를 디스크에 미리 구워(Preloading) 부팅 속도 획기적 단축<br>• **보안**: Autopilot용 이미지 허용 정책 적용 | GPU | Autopilot |
| 03 | **[GCS Fuse](./serving/03-gpu-vllm-gemma-3-gcsfuse/)** | • **스토리지 유연성**: GCS 버킷을 로컬 디스크처럼 마운트<br>• **모델 관리**: 별도 다운로드 없이 대용량 모델 즉시 로드 | GPU | Autopilot |
| 04 | **[Hyperdisk ML](./serving/04-gpu-vllm-gemma-3-hdml/)** | • **초고속 로딩**: 모델 로딩 시간 단축 (최대 100GB/s)<br>• **ReadOnlyMany**: 하나의 디스크로 수천 개의 Pod 동시 서빙 | GPU | Autopilot |
| 05 | **[Inference Gateway](./serving/05-gpu-vllm-gemma-3-inferencegw/)** | • **멀티 모델**: 하나의 Base 모델에 여러 LoRA 어댑터 적용<br>• **트래픽 라우팅**: 요청 헤더/경로 기반의 지능형 라우팅 | GPU | Autopilot |
| 06 | **[TPU Serving](./serving/06-tpu-vllm-gemma-3-gcsfuse/)** | • **TPU 가속**: Google Cloud TPU v6e를 활용한 고성능/저비용 추론<br>• **vLLM on TPU**: TPU에 최적화된 vLLM 구성 | TPU | Autopilot |
| 07 | **[TPU/GPU Fungibility](./serving/07-tpu-gpu-fungibility/)** | • **자원 유연성**: TPU와 GPU(Spot/On-demand)를 혼합하여 가용성 극대화<br>• **Custom Compute Class**: 리소스 우선순위 기반의 동적 스케줄링 | GPU & TPU | Standard |

## 🛠 시작하기 전 준비사항 (Prerequisites)

이 가이드를 따라하기 위해 다음 도구와 권한이 필요합니다.

1.  **Google Cloud 프로젝트**:
    *   결제가 활성화된 프로젝트.
    *   필요한 API 활성화 (`container.googleapis.com`, `compute.googleapis.com`, `monitoring.googleapis.com` 등).
2.  **클라이언트 도구**:
    *   [Google Cloud SDK (`gcloud`)](https://cloud.google.com/sdk/docs/install)
    *   [Kubernetes CLI (`kubectl`)](https://kubernetes.io/docs/tasks/tools/)
    *   [`jq`](https://stedolan.github.io/jq/) (JSON 응답 처리용)
    *   [`helm`](https://helm.sh/) (Inference Gateway 예제 등 일부 필요)
3.  **Hugging Face 계정 및 토큰**:
    *   [Hugging Face](https://huggingface.co/) 계정 생성.
    *   **Gemma 3** 모델 페이지(예: `google/gemma-3-4b-it`)에서 사용 약관 동의(Access Approval) 필요.
    *   `Read` 권한이 있는 Access Token 생성.
4.  **리소스 할당량 (Quota)**:
    *   GPU (L4, A100 등) 또는 TPU (v6e 등) 사용을 위한 적절한 Quota 확보 필요.

## 🏃‍♂️ 사용 방법 (How to Use)

1.  이 저장소를 클론합니다.
    ```bash
    git clone <REPOSITORY_URL>
    cd gke-aiml
    ```
2.  원하는 시나리오의 디렉토리로 이동합니다. (예: 기본 vLLM 배포)
    ```bash
    cd serving/01-gpu-vllm-gemma-3
    ```
3.  각 디렉토리의 `README.md`에 기술된 단계별 절차를 따릅니다.

## 📚 참고 자료 (References)

*   [Google Kubernetes Engine 문서](https://cloud.google.com/kubernetes-engine/docs)
*   [vLLM 공식 문서](https://docs.vllm.ai/)
*   [Gemma 모델 카드 (Hugging Face)](https://huggingface.co/google/gemma-3-4b-it)
*   [GKE AI/ML 레시피](https://gke-ai-labs.dev/)