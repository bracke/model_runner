#!/usr/bin/env python3
"""Record the reference vision tower's rows for the frames under plaza-frames/
into qwen35-0.8b-frames.expect.

Run with transformers, torch and Pillow installed; downloads Qwen/Qwen3.5-0.8B.
What it records and how tests see --frames --expect checks it is written at
the head of the file it writes.
"""
import glob, os, numpy as np, torch, transformers
from PIL import Image
from transformers import AutoModelForImageTextToText, AutoProcessor
R = os.path.dirname(os.path.abspath(__file__)) + "/"
FPS = 2.0
p = AutoProcessor.from_pretrained('Qwen/Qwen3.5-0.8B')
model = AutoModelForImageTextToText.from_pretrained('Qwen/Qwen3.5-0.8B', dtype=torch.float32); model.eval()
paths = sorted(glob.glob(R + 'plaza-frames/*.png'))
frames = [Image.open(f).convert('RGB') for f in paths]
meta = {"fps": FPS, "frames_indices": list(range(len(frames))), "total_num_frames": len(frames)}
probe = p.video_processor(videos=[frames], video_metadata=[meta], do_sample_frames=False, cap_pixels_per_frame=True, return_tensors='pt')
t, h, w = probe['video_grid_thw'][0].tolist()
resized = [f.resize((w * 16, h * 16), Image.BICUBIC) for f in frames]
pixels = p.video_processor(videos=[resized], video_metadata=[meta], do_sample_frames=False, cap_pixels_per_frame=True, return_tensors='pt')
with torch.no_grad():
    out = model.model.visual(pixels['pixel_values_videos'].float(), grid_thw=pixels['video_grid_thw'])
    rows = (out.pooler_output if hasattr(out, 'pooler_output') else out[0]).numpy()
rows_n, width = rows.shape
print('frames', len(frames), 'resized to', resized[0].size, 'grid', t, h // 2, w // 2, 'rows', rows.shape)
with open(R + 'qwen35-0.8b-frames.expect', 'w') as f:
    f.write('''# Recorded from the reference runtime by tests/fixtures/vision-crossing/
# record_frames.py: transformers %s, torch %s, Qwen/Qwen3.5-0.8B in binary32,
# the five frames under plaza-frames/ handed to the reference vision tower as
# one video -- its frames in pairs, the last paired with itself, each pair
# through the two temporal patch weights -- at the size its video
# processor's smart_resize picks with the per-frame cap the reference
# implementation applies, resized by PIL's BICUBIC, which is what this
# build's cubic filter resamples to, bit for bit. The projector this refers
# to is NOT committed; see docs/fixture-provenance.md for the mmproj file.
#
# Checked by:
#   tests see --mmproj qwen3.5-0.8b-mmproj-f16.gguf \\
#     --frames tests/fixtures/vision-crossing/plaza-frames \\
#     --expect tests/fixtures/vision-crossing/qwen35-0.8b-frames.expect
#
# which compares the grid a pair becomes, the slots, the row count and
# three rows in full -- the first, the middle and the last, which lie in
# three different slots -- each within the tolerance of its own norm. The
# projector's weights are f16 where the reference's are f32. No mandatory
# test reads this file.

runtime transformers %s
projector qwen3.5-0.8b-mmproj-f16.gguf
frames plaza-frames
fps %g
resized %d %d
grid %d %d
slots %d
rows %d
width %d
tolerance 0.01
''' % (transformers.__version__, torch.__version__, transformers.__version__, FPS, resized[0].size[0], resized[0].size[1], h // 2, w // 2, t, rows_n, width))
    for index in (0, rows_n // 2, rows_n - 1):
        f.write('row %d ' % index + ' '.join('%.7g' % v for v in rows[index]) + '\n')
print('written', R + 'qwen35-0.8b-frames.expect')
