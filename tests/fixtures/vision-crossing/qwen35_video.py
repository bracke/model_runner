#!/usr/bin/env python3
"""Set this build's reading of a video file beside the reference runtime.

Run from a checkout, with transformers, torch, torchcodec and Pillow
installed:

    tests see --mmproj MMPROJ --frames VIDEO --dump VIDEO.rows
    python3 tests/fixtures/vision-crossing/qwen35_video.py VIDEO VIDEO.rows

It downloads Qwen/Qwen3.5-0.8B (about 1.6 GB), reads the video as the
reference processor reads one -- through torchcodec, its default decoder,
sampled at two frames a second between four and seven hundred and
sixty-eight frames, with the per-frame pixel cap the reference
implementation applies -- and reports:

- the frames it took, by number, and the video's rate and frame count as
  its decoder states them, which this build takes from the container's
  own count or its packets, and its average rate;
- the prompt the reference processor makes of the video and a question,
  decoded, whose token count this build's --show-stats should match;
- the rows the reference vision tower makes of the video as it decoded
  and resized it, against the rows this build dumped. Here the two
  decode and resize on their own: the reference's decoder converts the
  frames to RGB its way and resizes with torchvision's bicubic, this
  build converts through libswscale and resizes as PIL does, so the rows
  agree to a few millionths of cosine rather than to the rounding, as
  the picture crossing's note on resampling says;
- the reference's greedy answer, for a reader setting it beside this
  build's.
"""
import sys
import numpy as np
import torch
from transformers import AutoModelForImageTextToText, AutoProcessor
from transformers.video_utils import load_video

NAME = 'Qwen/Qwen3.5-0.8B'
QUESTION = 'Describe what you see in this video in one sentence.'


def main(path, rows_path):
    processor = AutoProcessor.from_pretrained(NAME)
    model = AutoModelForImageTextToText.from_pretrained(NAME, dtype=torch.float32)
    model.eval()

    messages = [{"role": "user", "content": [{"type": "video", "video": path},
                                             {"type": "text", "text": QUESTION}]}]
    text = processor.apply_chat_template(messages, add_generation_prompt=True, tokenize=False)
    inputs = processor(text=[text], videos=[path], cap_pixels_per_frame=True, return_tensors='pt')
    t, h, w = inputs['video_grid_thw'][0].tolist()
    _, meta = load_video(path, backend='torchcodec',
                         sample_indices_fn=lambda metadata, **kw: processor.video_processor.sample_frames(metadata, fps=2))
    print('the video:', meta.total_num_frames, 'frames at', meta.fps, 'a second; frames taken', list(meta.frames_indices))
    print('grid (t, h, w) in patches', (t, h, w), '; fit', w * 16, 'x', h * 16,
          '; prompt tokens', inputs['input_ids'].shape[1])
    print('the prompt, decoded:', repr(processor.tokenizer.decode(inputs['input_ids'][0].tolist())))

    with torch.no_grad():
        out = model.model.visual(inputs['pixel_values_videos'].float(), grid_thw=inputs['video_grid_thw'])
        reference = (out.pooler_output if hasattr(out, 'pooler_output') else out[0]).numpy()
    ours = np.loadtxt(rows_path).reshape(reference.shape)
    cosine = (ours * reference).sum(1) / np.sqrt((ours ** 2).sum(1) * (reference ** 2).sum(1))
    apart = np.sqrt(((ours - reference) ** 2).sum(1))
    norm = np.median(np.sqrt((reference ** 2).sum(1)))
    print('rows', reference.shape, '; cosine min %.7f' % cosine.min(),
          '; worst row apart by %.5f of the median norm' % (apart.max() / norm))

    with torch.no_grad():
        made = model.generate(**inputs, max_new_tokens=60, do_sample=False)
    print('the reference answers:',
          repr(processor.tokenizer.decode(made[0][inputs['input_ids'].shape[1]:], skip_special_tokens=True)))


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
