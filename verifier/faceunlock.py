"""FaceUnlock 얼굴 등록/확인 도구.

일반 RGB 웹캠으로 얼굴을 찍어 OpenCV YuNet(검출) + SFace(특징 추출) 모델로 비교한다.
잠금 화면의 Credential Provider(FaceUnlockProvider.dll)가 `verify` 를 실행하고
종료 코드로 결과를 받는다.

종료 코드
    0  일치 (잠금 해제)
    1  불일치 / 시간 초과
    2  등록된 얼굴 없음
    3  카메라 열기 실패
    4  모델 파일 없음 / 기타 오류

명령
    enroll   얼굴 등록 (관리자 권한 필요: 템플릿이 관리자 전용 폴더에 저장됨)
             --append 로 기존 등록에 다른 각도/조명/안경 샘플을 추가
    verify   얼굴 확인 (잠금 화면에서 사용)
    test     점수를 계속 출력하며 임계값 조정용으로 확인
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from dataclasses import dataclass, asdict
from pathlib import Path

import numpy as np

EXIT_MATCH, EXIT_NO_MATCH, EXIT_NOT_ENROLLED, EXIT_CAMERA, EXIT_ERROR = 0, 1, 2, 3, 4

if getattr(sys, "frozen", False):  # PyInstaller 로 빌드된 exe
    APP_DIR = Path(sys.executable).resolve().parent
else:
    APP_DIR = Path(__file__).resolve().parent

MODEL_DIR = APP_DIR / "models"
DETECTOR_MODEL = "face_detection_yunet_2023mar.onnx"
RECOGNIZER_MODEL = "face_recognition_sface_2021dec.onnx"

DATA_DIR = Path(os.environ.get("FACEUNLOCK_DATA") or
                Path(os.environ.get("PROGRAMDATA", r"C:\ProgramData")) / "FaceUnlock")
TEMPLATE_FILE = DATA_DIR / "face.npz"
CONFIG_FILE = DATA_DIR / "config.json"
LOG_FILE = DATA_DIR / "verify.log"


@dataclass
class Config:
    # SFace 코사인 유사도. OpenCV 권장 기준은 0.363, 여기서는 오인식을 줄이려고 더 엄격하게 둔다.
    threshold: float = 0.45
    # 연속으로 이 횟수만큼 기준을 넘어야 일치로 본다 (한 프레임 우연 일치 방지).
    consecutive: int = 3
    timeout_sec: float = 10.0
    camera_index: int = 0
    # 이보다 작은 얼굴(픽셀)은 무시 - 멀리 있는 사람/사진 배제
    min_face_px: int = 80
    enroll_samples: int = 15

    @classmethod
    def load(cls) -> "Config":
        cfg = cls()
        try:
            data = json.loads(CONFIG_FILE.read_text(encoding="utf-8"))
            for k, v in data.items():
                if hasattr(cfg, k):
                    setattr(cfg, k, type(getattr(cfg, k))(v))
        except FileNotFoundError:
            pass
        except Exception as e:  # 설정이 깨져도 기본값으로 동작
            log(f"config error: {e}")
        # 기준을 낮춰 아무 얼굴이나 통과하게 만드는 설정은 받지 않는다 (다른 사람 점수는 보통 0.3 이하)
        if not 0.3 <= cfg.threshold <= 1.0:
            log(f"config error: threshold {cfg.threshold} out of range, using default")
            cfg.threshold = cls.threshold
        if cfg.consecutive < 1:
            log(f"config error: consecutive {cfg.consecutive} < 1, using default")
            cfg.consecutive = cls.consecutive
        return cfg


def log(msg: str) -> None:
    try:
        DATA_DIR.mkdir(parents=True, exist_ok=True)
        if LOG_FILE.exists() and LOG_FILE.stat().st_size > 512 * 1024:
            LOG_FILE.replace(LOG_FILE.with_suffix(".log.old"))
        with LOG_FILE.open("a", encoding="utf-8") as f:
            f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}\n")
    except OSError:
        pass


# ---------------------------------------------------------------------------
# 판정 로직 (카메라/모델 없이 테스트 가능하도록 분리)
# ---------------------------------------------------------------------------
def normalize(v: np.ndarray) -> np.ndarray:
    v = np.asarray(v, dtype=np.float32).ravel()
    n = float(np.linalg.norm(v))
    return v / n if n > 0 else v


def drop_outliers(feats: np.ndarray, threshold: float) -> np.ndarray:
    """다른 샘플들과의 평균 유사도가 기준 미만인 샘플(흐림, 고개 많이 돌림 등)을 뺀다."""
    if len(feats) < 3:
        return feats
    sims = feats @ feats.T
    mean_other = (sims.sum(axis=1) - np.diag(sims)) / (len(feats) - 1)
    return feats[mean_other >= threshold]


def failure_reason(counts: dict) -> str:
    """verify 실패 시 가장 많았던 원인: no_face(얼굴 없음) / small(얼굴 작음) / low(점수 부족)."""
    fails = {k: counts.get(k, 0) for k in ("no_face", "small", "low")}
    return max(fails, key=fails.get) if any(fails.values()) else "no_frames"


def best_score(feature: np.ndarray, templates: np.ndarray) -> float:
    """등록된 템플릿들과의 코사인 유사도 최댓값."""
    f = normalize(feature)
    t = templates / np.linalg.norm(templates, axis=1, keepdims=True)
    return float(np.max(t @ f))


class Decider:
    """연속 N 프레임 이상 기준을 넘으면 일치."""

    def __init__(self, threshold: float, consecutive: int):
        self.threshold = threshold
        self.consecutive = max(1, consecutive)
        self.streak = 0

    def feed(self, score: float | None) -> bool:
        if score is not None and score >= self.threshold:
            self.streak += 1
        else:
            self.streak = 0
        return self.streak >= self.consecutive


def select_largest(faces, min_px: int):
    """YuNet 결과(N x 15) 중 가장 큰 얼굴. 너무 작으면 None."""
    if faces is None or len(faces) == 0:
        return None
    face = max(faces, key=lambda f: f[2] * f[3])
    if min(face[2], face[3]) < min_px:
        return None
    return face


# ---------------------------------------------------------------------------
# 카메라 / 모델
# ---------------------------------------------------------------------------
# 평균 밝기(0~255)가 이보다 낮은 프레임만 CLAHE 로 보정한다.
# LFW 실험: 아주 어두운 동일인 쌍 통과 73/400 -> 181/400, 타인 점수는 오르지 않음.
DARK_LEVEL = 50


class Engine:
    def __init__(self):
        import cv2

        det = MODEL_DIR / DETECTOR_MODEL
        rec = MODEL_DIR / RECOGNIZER_MODEL
        for p in (det, rec):
            if not p.exists():
                raise FileNotFoundError(f"모델 파일 없음: {p}")
        self.cv2 = cv2
        self.detector = cv2.FaceDetectorYN.create(str(det), "", (320, 320), 0.9, 0.3, 5000)
        self.recognizer = cv2.FaceRecognizerSF.create(str(rec), "")
        self.clahe = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8))

    def enhance(self, frame):
        """밝기 채널만 국소 대비 보정."""
        cv2 = self.cv2
        lab = cv2.cvtColor(frame, cv2.COLOR_BGR2LAB)
        lab[..., 0] = self.clahe.apply(lab[..., 0])
        return cv2.cvtColor(lab, cv2.COLOR_LAB2BGR)

    def feature(self, frame, min_px: int):
        """(특징 벡터 | None, 상태) 상태: ok / no_face / small"""
        if float(frame.mean()) < DARK_LEVEL:
            frame = self.enhance(frame)
        h, w = frame.shape[:2]
        self.detector.setInputSize((w, h))
        _, faces = self.detector.detect(frame)
        if faces is None or len(faces) == 0:
            return None, "no_face"
        face = select_largest(faces, min_px)
        if face is None:
            return None, "small"
        aligned = self.recognizer.alignCrop(frame, face)
        return normalize(self.recognizer.feature(aligned)), "ok"


def open_camera(index: int):
    import cv2

    backends = [cv2.CAP_MSMF, cv2.CAP_DSHOW, cv2.CAP_ANY] if os.name == "nt" else [cv2.CAP_ANY]
    for be in backends:
        cap = cv2.VideoCapture(index, be)
        if cap.isOpened():
            cap.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
            cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
            # 자동 노출이 잡히도록 몇 프레임 버린다
            for _ in range(5):
                cap.read()
            return cap
        cap.release()
    return None


# ---------------------------------------------------------------------------
# 명령
# ---------------------------------------------------------------------------
def cmd_enroll(cfg: Config, preview: bool, append: bool = False) -> int:
    existing = load_templates() if append else None
    if append and existing is None:
        print("추가할 기존 등록이 없습니다. --append 없이 먼저 등록하세요.")
        return EXIT_NOT_ENROLLED
    engine = Engine()
    cap = open_camera(cfg.camera_index)
    if cap is None:
        print("카메라를 열 수 없습니다.")
        return EXIT_CAMERA

    print("카메라를 바라보세요. 고개를 조금씩 좌우/위아래로 움직이면 인식률이 좋아집니다.")
    feats: list[np.ndarray] = []
    last = 0.0
    deadline = time.time() + 60
    try:
        while len(feats) < cfg.enroll_samples and time.time() < deadline:
            ok, frame = cap.read()
            if not ok:
                continue
            if preview:
                engine.cv2.imshow("FaceUnlock enroll (q: cancel)", frame)
                if engine.cv2.waitKey(1) & 0xFF == ord("q"):
                    return EXIT_ERROR
            if time.time() - last < 0.4:  # 비슷한 프레임만 쌓이지 않도록 간격을 둔다
                continue
            f, _ = engine.feature(frame, cfg.min_face_px)
            if f is None:
                continue
            feats.append(f)
            last = time.time()
            print(f"  {len(feats)}/{cfg.enroll_samples}")
    finally:
        cap.release()
        if preview:
            engine.cv2.destroyAllWindows()

    if len(feats) < max(5, cfg.enroll_samples // 2):
        print("얼굴을 충분히 찍지 못했습니다. 밝은 곳에서 다시 시도하세요.")
        return EXIT_NO_MATCH

    arr = drop_outliers(np.stack(feats), cfg.threshold)
    if len(arr) < len(feats):
        print(f"품질이 낮은 샘플 {len(feats) - len(arr)}개를 뺐습니다.")
    if len(arr) < 3:
        print("쓸 만한 샘플이 부족합니다. 혼자 카메라 앞에서 다시 시도하세요.")
        return EXIT_NO_MATCH
    # 등록 샘플끼리 서로 비슷한지(다른 사람이 섞이지 않았는지) 확인
    sims = arr @ arr.T
    mean_sim = float((sims.sum() - len(arr)) / (len(arr) * (len(arr) - 1)))
    if mean_sim < cfg.threshold:
        print(f"등록 샘플 일관성이 낮습니다 ({mean_sim:.2f}). 혼자 카메라 앞에서 다시 시도하세요.")
        return EXIT_NO_MATCH

    if existing is not None:
        # 새 묶음이 기존 등록과 같은 사람인지: 최소 한 장은 기존 얼굴과 기준 이상으로 맞아야 한다.
        link = max(best_score(f, existing) for f in arr)
        if link < cfg.threshold:
            print(f"기존 등록 얼굴과 다른 사람으로 보입니다 (최고 {link:.2f}). 추가하지 않습니다.")
            return EXIT_NO_MATCH
        arr = np.concatenate([existing, arr])

    DATA_DIR.mkdir(parents=True, exist_ok=True)
    np.savez(TEMPLATE_FILE, features=arr)
    if not CONFIG_FILE.exists():
        CONFIG_FILE.write_text(json.dumps(asdict(cfg), indent=2), encoding="utf-8")
    print(f"등록 완료: {len(arr)}개 샘플, 평균 유사도 {mean_sim:.2f} -> {TEMPLATE_FILE}")
    log(f"enroll{' append' if append else ''} ok samples={len(arr)} mean={mean_sim:.3f}")
    return EXIT_MATCH


def load_templates() -> np.ndarray | None:
    try:
        with np.load(TEMPLATE_FILE) as z:
            return z["features"].astype(np.float32)
    except (FileNotFoundError, KeyError, ValueError):
        return None


def cmd_verify(cfg: Config, verbose: bool, forever: bool = False) -> int:
    templates = load_templates()
    if templates is None:
        log("verify: not enrolled")
        return EXIT_NOT_ENROLLED
    engine = Engine()
    cap = open_camera(cfg.camera_index)
    if cap is None:
        log("verify: camera open failed")
        return EXIT_CAMERA

    decider = Decider(cfg.threshold, cfg.consecutive)
    start = time.time()
    deadline = start + cfg.timeout_sec
    best = -1.0
    counts = {"frames": 0, "no_face": 0, "small": 0, "low": 0}
    bright = 0.0
    labels = {"no_face": "얼굴 없음", "small": "얼굴이 너무 작음 (가까이)"}

    def stats() -> str:
        return (f"best={best:.3f} t={time.time() - start:.1f}s frames={counts['frames']} no_face={counts['no_face']} "
                f"small={counts['small']} low={counts['low']} bright={bright / max(1, counts['frames']):.0f}")

    try:
        while forever or time.time() < deadline:
            ok, frame = cap.read()
            if not ok:
                continue
            counts["frames"] += 1
            bright += float(frame.mean())
            f, status = engine.feature(frame, cfg.min_face_px)
            score = None if f is None else best_score(f, templates)
            if score is None:
                counts[status] += 1
            else:
                best = max(best, score)
                counts["low"] += score < cfg.threshold
            if verbose:
                print(labels.get(status) or f"점수 {score:.3f} (기준 {cfg.threshold})", flush=True)
            if decider.feed(score) and not forever:
                log(f"verify: match {stats()}")
                return EXIT_MATCH
    except KeyboardInterrupt:
        pass
    finally:
        cap.release()
    log(f"verify: no match reason={failure_reason(counts)} {stats()}")
    return EXIT_NO_MATCH


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="faceunlock")
    sub = p.add_subparsers(dest="cmd", required=True)
    e = sub.add_parser("enroll", help="얼굴 등록")
    e.add_argument("--preview", action="store_true", help="카메라 화면 표시")
    e.add_argument("--append", action="store_true", help="기존 등록을 지우지 않고 샘플 추가")
    v = sub.add_parser("verify", help="얼굴 확인 (종료 코드로 결과)")
    v.add_argument("--verbose", action="store_true")
    sub.add_parser("test", help="점수를 계속 출력 (Ctrl+C 종료)")
    args = p.parse_args(argv)

    cfg = Config.load()
    try:
        if args.cmd == "enroll":
            return cmd_enroll(cfg, args.preview, args.append)
        if args.cmd == "verify":
            return cmd_verify(cfg, args.verbose)
        return cmd_verify(cfg, verbose=True, forever=True)
    except FileNotFoundError as e:
        print(e)
        log(f"{args.cmd}: {e}")
        return EXIT_ERROR
    except Exception as e:  # 잠금 화면에서 예외로 멈추지 않도록 항상 코드로 끝낸다
        log(f"{args.cmd}: unexpected {type(e).__name__}: {e}")
        print(f"오류: {e}")
        return EXIT_ERROR


if __name__ == "__main__":
    sys.exit(main())
