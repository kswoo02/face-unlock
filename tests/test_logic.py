"""카메라·모델 없이 판정 로직만 검사한다.  python -m pytest tests  또는  python tests/test_logic.py"""
import json
import os
import sys
import tempfile
from pathlib import Path

import numpy as np

os.environ["FACEUNLOCK_DATA"] = tempfile.mkdtemp()
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "verifier"))
import faceunlock as fu  # noqa: E402


def test_best_score_identical_and_orthogonal():
    t = np.eye(4, dtype=np.float32)
    assert abs(fu.best_score(np.array([2, 0, 0, 0]), t) - 1.0) < 1e-6
    assert abs(fu.best_score(np.array([1, 1, 0, 0]), t) - 0.70710677) < 1e-5


def test_decider_needs_consecutive_frames():
    d = fu.Decider(0.5, 3)
    assert not d.feed(0.9)
    assert not d.feed(0.9)
    assert not d.feed(None)  # 얼굴이 빠지면 처음부터
    assert not d.feed(0.9)
    assert not d.feed(0.9)
    assert d.feed(0.9)


def test_decider_rejects_below_threshold():
    d = fu.Decider(0.5, 1)
    assert not d.feed(0.49)
    assert d.feed(0.5)


def test_select_largest_and_min_size():
    faces = np.array([[0, 0, 50, 50] + [0] * 11, [0, 0, 120, 130] + [0] * 11], dtype=np.float32)
    assert fu.select_largest(faces, 80)[2] == 120
    assert fu.select_largest(faces[:1], 80) is None
    assert fu.select_largest(None, 80) is None


def test_config_load_overrides_and_bad_file():
    fu.DATA_DIR.mkdir(parents=True, exist_ok=True)
    fu.CONFIG_FILE.write_text(json.dumps({"threshold": 0.6, "unknown": 1}), encoding="utf-8")
    assert fu.Config.load().threshold == 0.6
    fu.CONFIG_FILE.write_text("{broken", encoding="utf-8")
    assert fu.Config.load().threshold == fu.Config().threshold


def test_verify_without_enrollment_returns_2():
    if fu.TEMPLATE_FILE.exists():
        fu.TEMPLATE_FILE.unlink()
    assert fu.cmd_verify(fu.Config(), verbose=False) == fu.EXIT_NOT_ENROLLED


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_"):
            fn()
            print("ok", name)
