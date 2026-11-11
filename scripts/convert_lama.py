#!/usr/bin/env python3
"""LaMa (big-lama) → Core ML 转换试验。

背景：微博水印是不透明白字，只能靠模型"补得像"。
LaMa 是当前开源 inpainting 里效果最好的（Photoshop 内容识别填充的 AI 版路线）。

本脚本目标不是产出最终模型，而是验证：
  1. 权重能否在 CI 里正常下载/加载
  2. TorchScript trace 是否通过（LaMa 的 FFC 层含 FFT）
  3. coremltools 能否转成 mlprogram（FFT 是已知不支持项，失败要明确报出来）
"""
import os
import sys
import traceback

import torch

WORK = os.path.dirname(os.path.abspath(__file__))
LAMA_DIR = os.path.join(WORK, "lama")
CKPT = os.path.join(WORK, "big-lama", "models", "best.ckpt")


def log(*a):
    print("[convert]", *a, flush=True)


def main() -> int:
    sys.path.insert(0, LAMA_DIR)

    if not os.path.exists(CKPT):
        log("checkpoint missing:", CKPT)
        return 2

    from omegaconf import OmegaConf
    from saicinpainting.training.trainers import load_checkpoint

    cfg_path = os.path.join(LAMA_DIR, "configs", "prediction", "default.yaml")
    config = OmegaConf.load(cfg_path)
    log("config loaded")

    model = load_checkpoint(config, "big-lama", "cpu", predict_only=True)
    model.eval()
    log("model loaded, params:", sum(p.numel() for p in model.parameters()) / 1e6, "M")

    # LaMa 前向：dict{image: [1,3,H,W], mask: [1,1,H,W]}，H/W 需为 8 的倍数
    H = W = 512

    class Wrap(torch.nn.Module):
        def __init__(self, m):
            super().__init__()
            self.m = m

        def forward(self, image, mask):
            return self.m({"image": image, "mask": mask})["inpainted"]

    wrap = Wrap(model).eval()
    img = torch.rand(1, 3, H, W)
    msk = torch.zeros(1, 1, H, W)
    msk[:, :, 200:300, 100:400] = 1.0

    try:
        with torch.no_grad():
            out = wrap(img, msk)
        log("eager forward ok, out shape:", tuple(out.shape))
    except Exception:
        log("eager forward FAILED")
        traceback.print_exc()
        return 3

    try:
        traced = torch.jit.trace(wrap, (img, msk), strict=False)
        traced = torch.jit.freeze(traced)
        log("torch.jit.trace ok")
    except Exception:
        log("torch.jit.trace FAILED")
        traceback.print_exc()
        return 4

    try:
        import coremltools as ct

        log("coremltools", ct.__version__)
        mlmodel = ct.convert(
            traced,
            inputs=[
                ct.TensorType(name="image", shape=(1, 3, H, W)),
                ct.TensorType(name="mask", shape=(1, 1, H, W)),
            ],
            outputs=[ct.TensorType(name="inpainted")],
            minimum_deployment_target=ct.target.iOS16,
            compute_precision=ct.precision.FLOAT16,
            convert_to="mlprogram",
        )
        out_path = os.path.join(WORK, "LaMaInpaint.mlpackage")
        mlmodel.save(out_path)
        log("CONVERT OK ->", out_path)
    except Exception:
        log("coremltools convert FAILED")
        traceback.print_exc()
        return 5
    return 0


if __name__ == "__main__":
    sys.exit(main())
