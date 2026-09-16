#!/usr/bin/env python3
"""Set this build's Gemma 3 prompt rewrite beside the reference processor.

Run from a checkout, with transformers and Pillow installed:

    python3 tests/fixtures/vision-crossing/gemma3.py PICTURE [PICTURE ...]

It loads the Gemma 3 processor from unsloth/gemma-3-4b-it -- the same
tokenizer and processor configuration as google's, which is gated -- and
for each picture compares the reference's prompt tokens, with and without
pan-and-scan, against the template's text rewritten as this build rewrites
it: every <start_of_image> set between two line breaks and opened into the
marker, 256 <image_soft_token>s and <end_of_image>; and a picture with
crops among the processor's words, "Here is the original image ... and
here are some crops to help you see better ...", the crop count by the
reference's rule as Model_Runner.Images.Pan_And_Scan states it.
"""
import sys
import numpy as np
from PIL import Image
from transformers import AutoProcessor

NAME = 'unsloth/gemma-3-4b-it'
FRAME = "\n\n<start_of_image>" + "<image_soft_token>" * 256 + "<end_of_image>\n\n"


def crops_of(width, height, min_crop=256, max_crops=4, min_ratio=1.2):
    longer, shorter = max(width, height), min(width, height)
    if longer / shorter < min_ratio:
        return 0
    count = int(np.floor(longer / shorter + 0.5))
    count = min(int(np.floor(longer / min_crop)), count)
    count = max(2, count)
    count = min(max_crops, count)
    along = int(np.ceil(longer / count))
    return 0 if min(along, shorter) < min_crop else count


def main(pictures):
    processor = AutoProcessor.from_pretrained(NAME)
    tok = processor.tokenizer
    for picture in pictures:
        image = Image.open(picture).convert('RGB')
        messages = [{"role": "user", "content": [{"type": "image"},
                                                 {"type": "text", "text": "Read every word of text in this picture."}]}]
        text = processor.apply_chat_template(messages, add_generation_prompt=True, tokenize=False)
        for pan_and_scan in (False, True):
            inputs = processor(text=[text], images=[image], return_tensors='pt', do_pan_and_scan=pan_and_scan)
            ids = inputs['input_ids'][0].tolist()
            crops = crops_of(*image.size) if pan_and_scan else 0
            if crops:
                written = text.replace('<start_of_image>',
                                       'Here is the original image ' + FRAME
                                       + ' and here are some crops to help you see better '
                                       + ' '.join([FRAME] * crops), 1)
            else:
                written = text.replace('<start_of_image>', FRAME)
            ours = tok(written, add_special_tokens=True)['input_ids']
            print(picture, 'with crops' if pan_and_scan else 'whole',
                  ': reference tokens', len(ids), ', tiles', int(inputs['pixel_values'].shape[0]),
                  '; the rewrite gives the same tokens:', ours == ids)


if __name__ == '__main__':
    main(sys.argv[1:])
