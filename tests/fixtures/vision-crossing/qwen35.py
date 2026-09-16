#!/usr/bin/env python3
"""Set this build's Qwen3.5 picture path beside the reference runtime.

Run from a checkout, with transformers, torch and Pillow installed:

    tests see --mmproj MMPROJ --image PICTURE --dump PICTURE.rows
    python3 tests/fixtures/vision-crossing/qwen35.py PICTURE PICTURE.rows

It downloads Qwen/Qwen3.5-0.8B (about 1.6 GB) and reports, for the
picture:

- the prompt tokens the reference processor makes of the picture and a
  question, against the template's tokens with the one <|image_pad|>
  replicated, which is what this build writes;
- the rows the reference vision tower makes of the picture, against the
  rows this build dumped -- on the same pixels: the reference is handed the
  picture resized by PIL's BICUBIC to the size its own smart_resize picks,
  which is what this build's cubic filter resamples to, bit for bit;
- the three-part positions the reference's get_rope_index assigns around
  the picture, which this build assigns as: the picture's start for time,
  its row and column for the rest, the text after it from the start plus
  the grid's longer side.

transformers 5 resizes with torchvision's bicubic, a = -0.75, in its
default processor; the slow processor the model was trained through, and
llama.cpp, resize as PIL does, a = -0.5, and so does this build. The two
differ by up to two levels a pixel, which the encoder can turn into rows a
third apart on a handful of windows; on identical pixels the rows agree to
a thousandth of their norm, which is the f16 weights.
"""
import sys
import numpy as np
import torch
from PIL import Image
from transformers import AutoModelForImageTextToText, AutoProcessor

NAME = 'Qwen/Qwen3.5-0.8B'
QUESTION = 'What is in this picture? Answer in one sentence.'


def main(picture, rows_path):
    processor = AutoProcessor.from_pretrained(NAME)
    tok = processor.tokenizer
    model = AutoModelForImageTextToText.from_pretrained(NAME, dtype=torch.float32)
    model.eval()

    image = Image.open(picture).convert('RGB')
    messages = [{"role": "user", "content": [{"type": "image", "image": picture},
                                             {"type": "text", "text": QUESTION}]}]
    text = processor.apply_chat_template(messages, add_generation_prompt=True, tokenize=False)
    inputs = processor(text=[text], images=[image], return_tensors='pt')
    ids = inputs['input_ids'][0].tolist()
    grid = inputs['image_grid_thw']
    pad = tok.convert_tokens_to_ids('<|image_pad|>')
    plain = tok(text, add_special_tokens=False)['input_ids']
    at = plain.index(pad)
    replicated = plain[:at] + [pad] * ids.count(pad) + plain[at + 1:]
    print('grid (t, h, w) in patches', grid[0].tolist(), '; prompt tokens', len(ids))
    print('the template tokens with the pad replicated are the reference tokens:', replicated == ids)

    # The reference tower on the pixels this build resamples to.
    t, h, w = grid[0].tolist()
    resized = image.resize((w * 16, h * 16), Image.BICUBIC)
    pixels = processor.image_processor(images=[resized], return_tensors='pt')
    with torch.no_grad():
        reference = model.model.visual(pixels['pixel_values'].float(),
                                       grid_thw=pixels['image_grid_thw']).pooler_output.numpy()
    ours = np.loadtxt(rows_path).reshape(reference.shape)
    cosine = (ours * reference).sum(1) / np.sqrt((ours ** 2).sum(1) * (reference ** 2).sum(1))
    apart = np.sqrt(((ours - reference) ** 2).sum(1))
    norm = np.median(np.sqrt((reference ** 2).sum(1)))
    print('rows', reference.shape, '; cosine min %.7f' % cosine.min(),
          '; worst row apart by %.5f of the median norm' % (apart.max() / norm))

    # The positions.
    kinds = (inputs['input_ids'] == model.config.image_token_id).int()
    positions, delta = model.model.get_rope_index(inputs['input_ids'], kinds, grid, None,
                                                  torch.ones_like(inputs['input_ids']))
    positions = positions[:, 0, :].numpy()
    first = ids.index(pad)
    count = ids.count(pad)
    rows, columns = h // 2, w // 2
    start = positions[0, first]
    expected = True
    for i in range(count):
        expected &= positions[:, first + i].tolist() == [start, start + i // columns, start + i % columns]
    after = positions[:, first + count].tolist()
    print('picture rows at (start, start + row, start + column):', expected,
          '; text after the picture at start + longer side:', after == [start + max(rows, columns)] * 3,
          '; rope delta', delta.flatten().tolist())


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
