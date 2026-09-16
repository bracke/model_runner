#!/usr/bin/env python3
"""Record the reference vision tower's rows for plaza.png into qwen35-0.8b.expect.

Run with transformers, torch and Pillow installed; downloads Qwen/Qwen3.5-0.8B.
What it records and how tests see --expect checks it is written at the head
of the file it writes.
"""
import numpy as np, torch, transformers
from PIL import Image
from transformers import AutoModelForImageTextToText, AutoProcessor
R = __import__("os").path.dirname(__import__("os").path.abspath(__file__)) + "/"
p = AutoProcessor.from_pretrained('Qwen/Qwen3.5-0.8B')
model = AutoModelForImageTextToText.from_pretrained('Qwen/Qwen3.5-0.8B', dtype=torch.float32); model.eval()
image = Image.open(R+'plaza.png').convert('RGB')
probe = p.image_processor(images=[image], return_tensors='pt')
t,h,w = probe['image_grid_thw'][0].tolist()
resized = image.resize((w*16, h*16), Image.BICUBIC)
pixels = p.image_processor(images=[resized], return_tensors='pt')
with torch.no_grad():
    rows = model.model.visual(pixels['pixel_values'].float(), grid_thw=pixels['image_grid_thw']).pooler_output.numpy()
rows_n, width = rows.shape
print('resized to', resized.size, 'grid', h//2, w//2, 'rows', rows.shape)
with open(R+'qwen35-0.8b.expect','w') as f:
    f.write('''# Recorded from the reference runtime by tests/fixtures/vision-crossing/qwen35.py's
# sibling, record_expect: transformers %s, torch %s, Qwen/Qwen3.5-0.8B in
# binary32, the picture beside this file handed to the reference vision tower
# at the size its smart_resize picks, resized by PIL's BICUBIC -- which is what
# this build's cubic filter resamples to, bit for bit. The projector this refers
# to is NOT committed; see docs/fixture-provenance.md for the mmproj file.
#
# Checked by:
#   tests see --mmproj qwen3.5-0.8b-mmproj-f16.gguf \\
#     --image tests/fixtures/vision-crossing/plaza.png \\
#     --expect tests/fixtures/vision-crossing/qwen35-0.8b.expect
#
# which compares the grid, the row count and three rows in full -- the
# first, the middle and the last -- each within the tolerance of its own
# norm. The projector's weights are f16 where the reference's are f32,
# which is a thousandth of a row's norm; the tolerance is ten times that.
# No mandatory test reads this file.

runtime transformers %s
projector qwen3.5-0.8b-mmproj-f16.gguf
picture plaza.png
resized %d %d
grid %d %d
rows %d
width %d
tolerance 0.01
''' % (transformers.__version__, torch.__version__, transformers.__version__, resized.size[0], resized.size[1], h//2, w//2, rows_n, width))
    for index in (0, rows_n//2, rows_n-1):
        f.write('row %d ' % index + ' '.join('%.7g' % v for v in rows[index]) + '\n')
