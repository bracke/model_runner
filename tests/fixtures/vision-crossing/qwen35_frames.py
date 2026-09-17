#!/usr/bin/env python3
"""Set this build's Qwen3.5 video path beside the reference runtime.

Run from a checkout, with transformers, torch and Pillow installed:

    tests see --mmproj MMPROJ --frames DIR --dump DIR.rows
    python3 tests/fixtures/vision-crossing/qwen35_frames.py DIR DIR.rows

It downloads Qwen/Qwen3.5-0.8B (about 1.6 GB) and reports, for the
frames under DIR taken as a video at two frames a second:

- the prompt the reference processor makes of the video and a question,
  decoded, against what this build writes: the template's one
  <|video_pad|> opened out, for every pair of frames, into the seconds the
  pair stands at, <|vision_start|>, one <|video_pad|> a row of the pair
  and <|vision_end|>, inside the <|vision_start|> and <|vision_end|> the
  template wrote round the video;
- the rows the reference vision tower makes of the video, against the
  rows this build dumped -- on the same pixels, every frame resized by
  PIL's BICUBIC to the size the reference's video smart_resize picks with
  the per-frame cap the reference implementation (qwen-vl-utils) applies,
  which transformers makes its default in 5.22;
- the reference's greedy answer to the question, for a reader setting it
  beside this build's.

The frames are given to the reference as frames rather than as a file, with
the metadata this build assumes -- frame i at i / fps seconds -- so that the
sampling a video file would go through is not part of what is compared;
reading a video file is what ffmpeg is for, on both sides.
"""
import glob, sys
import numpy as np
import torch
from PIL import Image
from transformers import AutoModelForImageTextToText, AutoProcessor

NAME = 'Qwen/Qwen3.5-0.8B'
QUESTION = 'What happens in this video? Answer in one sentence.'
FPS = 2.0


def main(frames_dir, rows_path):
    processor = AutoProcessor.from_pretrained(NAME)
    model = AutoModelForImageTextToText.from_pretrained(NAME, dtype=torch.float32)
    model.eval()

    paths = sorted(glob.glob(frames_dir + '/*'))
    frames = [Image.open(f).convert('RGB') for f in paths]
    meta = {"fps": FPS, "frames_indices": list(range(len(frames))), "total_num_frames": len(frames)}
    messages = [{"role": "user", "content": [{"type": "video", "video": frames_dir},
                                             {"type": "text", "text": QUESTION}]}]
    text = processor.apply_chat_template(messages, add_generation_prompt=True, tokenize=False)
    inputs = processor(text=[text], videos=[frames], video_metadata=[meta], do_sample_frames=False,
                       cap_pixels_per_frame=True, return_tensors='pt')
    t, h, w = inputs['video_grid_thw'][0].tolist()
    print('frames', len(frames), '; grid (t, h, w) in patches', (t, h, w), '; fit', w * 16, 'x', h * 16,
          '; prompt tokens', inputs['input_ids'].shape[1])
    print('the prompt, decoded:', repr(processor.tokenizer.decode(inputs['input_ids'][0].tolist())))

    # The reference tower on the pixels this build resamples to.
    resized = [f.resize((w * 16, h * 16), Image.BICUBIC) for f in frames]
    pixels = processor.video_processor(videos=[resized], video_metadata=[meta], do_sample_frames=False,
                                       cap_pixels_per_frame=True, return_tensors='pt')
    with torch.no_grad():
        out = model.model.visual(pixels['pixel_values_videos'].float(), grid_thw=pixels['video_grid_thw'])
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
