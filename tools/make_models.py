"""Author the "Look" Core ML models: a small colour-grade + sharpen network on 3x256x256 images.

Writes Models/Look.mlmodel (float32), Models/LookInt8.mlmodel (8-bit weights, what ships),
Models/Look2bit.mlmodel (2-bit: what a bad quantization looks like), and Models/look_weights.json,
the same weights for the Swift reference implementation (the oracle the model is checked against).
Deterministic: fixed seed, so the models are byte-stable across runs.
"""
from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import coremltools as ct
from coremltools.models import datatypes
from coremltools.models.neural_network import NeuralNetworkBuilder
from coremltools.models.neural_network import quantization_utils

OUT = Path(__file__).resolve().parent.parent / "Models"
ENCODING = "utf-8"
H = W = 256


def weights() -> dict:
    rng = np.random.default_rng(2026)
    # 1x1 colour matrix: a warm "film" grade with slight crosstalk.
    grade = np.array([[1.08, 0.06, -0.04], [0.02, 1.00, 0.02], [-0.05, 0.04, 0.88]], dtype=np.float32)
    grade += rng.normal(0, 0.01, (3, 3)).astype(np.float32)
    grade_bias = np.array([0.02, 0.0, -0.02], dtype=np.float32)
    # 3x3 depthwise-as-full sharpen: centre 1 + k, neighbours -k/8 per channel.
    k = 0.6
    sharpen = np.zeros((3, 3, 3, 3), dtype=np.float32)  # [out, in, kh, kw]
    for c in range(3):
        sharpen[c, c] = -k / 8
        sharpen[c, c, 1, 1] = 1 + k
    sharpen += rng.normal(0, 0.002, sharpen.shape).astype(np.float32)
    return {"grade": grade, "grade_bias": grade_bias, "sharpen": sharpen}


def build(w: dict) -> ct.models.MLModel:
    inputs = [("image", datatypes.Array(1, 3, H, W))]
    outputs = [("graded", datatypes.Array(1, 3, H, W))]
    b = NeuralNetworkBuilder(inputs, outputs, disable_rank5_shape_mapping=True)
    b.add_convolution("grade", kernel_channels=3, output_channels=3, height=1, width=1, stride_height=1, stride_width=1,
                      border_mode="valid", groups=1, W=w["grade"].reshape(3, 3, 1, 1).transpose(2, 3, 1, 0),
                      b=w["grade_bias"], has_bias=True, input_name="image", output_name="graded_lin")
    b.add_convolution("sharpen", kernel_channels=3, output_channels=3, height=3, width=3, stride_height=1, stride_width=1,
                      border_mode="same", groups=1, W=w["sharpen"].transpose(2, 3, 1, 0), b=None, has_bias=False,
                      input_name="graded_lin", output_name="sharp")
    b.add_clip("clip", input_name="sharp", output_name="graded", min_value=0.0, max_value=1.0)
    spec = b.spec
    spec.description.metadata.shortDescription = "vision-gate Look: colour grade + sharpen (test model)"
    spec.description.metadata.versionString = "1.0"
    return ct.models.MLModel(spec, skip_model_load=True)


def main() -> None:
    OUT.mkdir(exist_ok=True)
    w = weights()
    model = build(w)
    model.save(str(OUT / "Look.mlmodel"))
    quantization_utils.quantize_weights(model, nbits=8, quantization_mode="linear").save(str(OUT / "LookInt8.mlmodel"))
    quantization_utils.quantize_weights(model, nbits=2, quantization_mode="linear").save(str(OUT / "Look2bit.mlmodel"))
    with (OUT / "look_weights.json").open("w", encoding=ENCODING) as f:
        json.dump({"grade": w["grade"].tolist(), "grade_bias": w["grade_bias"].tolist(), "sharpen": w["sharpen"].tolist(),
                   "height": H, "width": W}, f)
    print("wrote", sorted(p.name for p in OUT.iterdir()))


if __name__ == "__main__":
    main()
