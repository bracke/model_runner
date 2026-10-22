#!/usr/bin/env python3
"""Record the reference vision tower's rows for plaza.png into qwen3vl-8b.expect.

Run with transformers, torch and Pillow installed, given a directory holding
Qwen/Qwen3-VL-8B-Instruct's config.json, preprocessor_config.json and the one
weight shard its vision tower lies in (model-00004-of-00004.safetensors): the
tower alone is built and read, the language model never.

    record_qwen3vl.py DIRECTORY

Each row recorded is the merger's row and the three deepstack mergers' rows
beside it, in that order -- the row Model_Runner.Vision.Encode makes.
"""
import json, os, sys
import numpy as np, torch, transformers
from PIL import Image
from safetensors import safe_open
from transformers import AutoConfig, AutoImageProcessor
from transformers.models.qwen3_vl.modeling_qwen3_vl import Qwen3VLVisionModel

R = os.path.dirname(os.path.abspath(__file__)) + "/"
D = sys.argv[1]
config = AutoConfig.from_pretrained(D)
tower = Qwen3VLVisionModel._from_config(config.vision_config, dtype=torch.float32).eval()
state = {}
with safe_open(D + "/model-00004-of-00004.safetensors", "pt") as f:
    for key in f.keys():
        if key.startswith("model.visual."):
            state[key[len("model.visual."):]] = f.get_tensor(key).float()
missing, unexpected = tower.load_state_dict(state, strict=False)
assert not missing and not unexpected, (missing, unexpected)

p = AutoImageProcessor.from_pretrained(D)
image = Image.open(R + "plaza.png").convert("RGB")
probe = p(images=[image], return_tensors="pt")
t, h, w = probe["image_grid_thw"][0].tolist()
resized = image.resize((w * 16, h * 16), Image.BICUBIC)
pixels = p(images=[resized], return_tensors="pt")
with torch.no_grad():
    out = tower(pixels["pixel_values"].float(), grid_thw=pixels["image_grid_thw"])
if isinstance(out, tuple):
    main, deep = out[0], out[1]
else:
    main, deep = out.pooler_output, out.deepstack_features
rows = torch.cat([main] + list(deep), dim=1).numpy()
rows_n, width = rows.shape
print("resized to", resized.size, "grid", h // 2, w // 2, "rows", rows.shape)
with open(R + "qwen3vl-8b.expect", "w") as f:
    f.write("""# Recorded from the reference runtime by tests/fixtures/vision-crossing/record_qwen3vl.py:
# transformers %s, torch %s, Qwen/Qwen3-VL-8B-Instruct's vision tower in binary32
# (its weights read from the one shard they lie in), the picture beside this
# file handed to it at the size its smart_resize picks, resized by PIL's
# BICUBIC. Each row is the merger's and the three deepstack mergers' beside it.
# The projector this refers to is NOT committed; see docs/fixture-provenance.md.
#
# Checked by:
#   tests see --mmproj mmproj-Qwen3VL-8B-Instruct-F16.gguf \\
#     --image tests/fixtures/vision-crossing/plaza.png \\
#     --expect tests/fixtures/vision-crossing/qwen3vl-8b.expect
#
# which compares the grid, the row count and three rows in full, each within
# the tolerance of its own norm.

runtime transformers %s
projector mmproj-Qwen3VL-8B-Instruct-F16.gguf
picture plaza.png
resized %d %d
grid %d %d
rows %d
width %d
tolerance 0.01
""" % (transformers.__version__, torch.__version__, transformers.__version__, resized.size[0], resized.size[1],
       h // 2, w // 2, rows_n, width))
    for index in (0, rows_n // 2, rows_n - 1):
        f.write("row %d " % index + " ".join("%.7g" % v for v in rows[index]) + "\n")
