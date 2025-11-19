# GKE AI/ML 활용 가이드

이 저장소는 Google Kubernetes Engine (GKE) 환경에서 AI/ML 워크로드를 효율적으로 구축하고 운영하기 위한 다양한 예제와 모범 사례를 제공합니다.

## 소개

이 프로젝트는 GKE의 강력한 기능을 활용하여 대규모 언어 모델(LLM) 추론(Inference)을 수행하는 방법을 단계별로 안내합니다. 특히 최신 **Gemma 3** 모델과 **vLLM** 추론 엔진을 기반으로, 다양한 스토리지 옵션과 최적화 기법을 다룹니다.

## 디렉토리 구조 및 예제

주요 예제 코드는 `inference` 폴더에 위치하며, 각 하위 폴더는 특정 시나리오를 다루고 있습니다.

### 📂 Inference (추론)

| 예제 (바로가기) | 주요 내용 | 특징 |
| :--- | :--- | :--- |
| **[01. Basic vLLM & Gemma 3](./inference/01-vllm-gemma-3/)** | 기본적인 vLLM 배포 | • Gemma 3 모델 (4B, 12B, 27B) 배포<br>• 표준적인 GKE 배포 방식 |
| **[02. Secondary Boot Disk](./inference/02-vllm-gemma-3-secondarybd/)** | 부팅 디스크 최적화 | • Secondary Boot Disk를 활용한 이미지 풀링 속도 향상<br>• 컨테이너 시작 시간 단축 |
| **[03. GCS Fuse](./inference/03-vllm-gemma-3-gcsfuse/)** | Cloud Storage 연동 | • GCS Fuse를 통한 모델 가중치 로드<br>• 대용량 모델의 유연한 스토리지 관리 |
| **[04. Hyperdisk ML](./inference/04-vllm-gemma-3-hdml/)** | 고성능 스토리지 | • Hyperdisk ML을 활용한 모델 로딩 가속화<br>• 빠른 I/O 성능이 필요한 경우 적합 |

## 시작하기 전 준비사항 (Prerequisites)

이 예제들을 실행하기 위해 다음 환경이 필요합니다.

1.  **Google Cloud 프로젝트**: 결제가 활성화된 프로젝트.
2.  **도구 설치**:
    *   `gcloud` CLI
    *   `kubectl`
3.  **GKE 클러스터**: GPU 노드 풀이 포함된 클러스터 (예: L4, A100 등).
4.  **Hugging Face 토큰**: Gemma 3 모델 접근 권한이 있는 토큰 (Secret 생성 시 필요).

## 사용 방법

각 디렉토리 내부에는 해당 예제에 대한 상세한 `README.md`와 Kubernetes 매니페스트 파일(`yaml`)이 포함되어 있습니다. 관심 있는 주제의 폴더로 이동하여 가이드를 따라 진행해 주세요.