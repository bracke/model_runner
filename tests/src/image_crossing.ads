with Ada.Strings.Unbounded;

--  Qwen-Image 2.1 on the published files, set beside the reference's own
--  numbers for the same prompt and seed: `tests image --expect FILE`.
--
--  The expectation is written by tests/fixtures/image-crossing/record.py
--  from a run of stable-diffusion.cpp through the mr-reference harness
--  (docs/plan-image-generation.md, step 0): the file it ran, the prompt,
--  the size, the seed and the steps; three of the text encoder's rows; and
--  the velocity of the first two steps. What is held to it:
--
--    the encoder's rows, each within the row tolerance of its own norm;
--
--    the velocity at the first noise level, from the seed's noise and this
--    program's rows, to the velocity cosine; and at the second, from the
--    latent the first moved, the prompt's rows kept from the first step;
--
--    with `--reference DIR`, the reference's latent after its last step
--    (DIR/latent40.f32) decoded and set beside its picture (picture.pam),
--    each channel at 40 dB PSNR or better.
--
--  The three files are the models directory's, by their published names, or
--  the paths the options give; a file that is not there is a skip, as an
--  external model that is not there is.
package Image_Crossing is

   --  The expectation, the three files where they are not the models
   --  directory's, the reference's run where its decoder is to be checked,
   --  and whether on the device.
   type Settings is record
      Expect    : Ada.Strings.Unbounded.Unbounded_String;
      On_Device : Boolean := False;
      Model, Text_Encoder, VAE : Ada.Strings.Unbounded.Unbounded_String;
      --  The vision projector an edit's pictures are read with.
      Projector : Ada.Strings.Unbounded.Unbounded_String;
      Reference : Ada.Strings.Unbounded.Unbounded_String;
      --  The decoder's stripe budget for the reference's latent, or nought
      --  for its own.
      Stripe_Bytes : Long_Long_Integer := 0;
   end record;

   --  Run the check, saying each figure as it is had.
   --
   --  @param Given what to check and with what
   --  @return nought where the expectation is met or a file is missing,
   --    one where it is not met or the run failed
   function Run (Given : Settings) return Natural;

end Image_Crossing;
