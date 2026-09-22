--  The pictures a conversation shows, gathered for the model.
--
--  A picture reaches the model as a part of a turn -- {"type": "image",
--  "path": "FILE"} -- and as the rows the vision projector makes of the
--  file. The template writes a marker for every image part it walks, in
--  the conversation's order, and the rows must stand behind the markers
--  in the same order; so the rows are gathered from the conversation as
--  it stands rather than from the option that added a turn, which is what
--  lets a turn typed at the terminal, a turn read back from a checkpoint
--  and a turn given on the command line all be the same thing.
--
--  A seer is the projector, opened once, together with the tokens the
--  text model frames a picture with. Gather walks a conversation's turns
--  and encodes every image part with a path that the picture set does not
--  hold yet, so that calling it again after a turn was added encodes only
--  the new picture.
--
--  A video reaches the model the same way -- {"type": "video", "path":
--  "DIR", "fps": 2} -- as a directory of frames, one picture a frame in
--  the order their names sort, taken at fps frames a second, which is
--  what the reference processor samples a video at unless told otherwise.
--  The frames go through the projector in pairs, a video with an odd
--  count pairing its last frame with itself, and each pair is a slot: a
--  picture of its own to the text model, stood among the words that say
--  when it was. Only a projector that reads video takes one; Gemma 3's
--  refuses it by name. Reading a video file is not done here: the frames
--  are taken from whatever wrote them out, ffmpeg -vf fps=2 or the like.
--
--  Pan-and-scan, when asked for, shows a wide or tall picture twice: whole,
--  and then in two to four crops along its longer side, each encoded as a
--  picture of its own and set in the prompt among the reference
--  processor's words -- "Here is the original image ... and here are some
--  crops to help you see better". A picture near square, or too small to
--  cut into crops of 256 pixels, is shown whole only, as the reference
--  shows it.
with Model_Runner.Backend.CPU;
with Model_Runner.Cancellation;
with Model_Runner.Conversation;
with Model_Runner.Errors;
with Model_Runner.Generation;
with Model_Runner.Llama;
with Model_Runner.Text;
with Model_Runner.Tokenizer;
with Model_Runner.Vision;

package Model_Runner.CLI.Pictures is

   --  Most pictures and videos one conversation may show, and most slots
   --  its videos may have between them -- the reference's most frames a
   --  video, in pairs.
   Max_Pictures : constant := 16;
   Max_Slots    : constant := 384;

   --  The rate a video's frames are taken to have been sampled at where
   --  the part names none: the reference processor's own.
   Default_Fps : constant := 2.0;

   type Seer is limited private;

   --  Open the projector and find the picture tokens in the model's
   --  vocabulary.
   --
   --  @param Item Seer to open.
   --  @param Projector The projector's GGUF file.
   --  @param Model The prepared text model the pictures are for.
   --  @param Status Success, Arch_Vision_Tokens_Missing when the model has
   --    no token for a picture to stand behind, Arch_Invalid_Dimensions
   --    when the projector's rows are not the model's width, or what
   --    opening the projector said.
   procedure Open
     (Item      : in out Seer;
      Projector : String;
      Model     : Model_Runner.Llama.Model'Class;
      Status    : out Model_Runner.Errors.Error_Info);

   --  Release the projector. Idempotent.
   --
   --  @param Item Seer to close.
   procedure Close (Item : in out Seer);

   --  Whether Open succeeded.
   --
   --  @param Item Seer to inspect.
   --  @return True when pictures can be gathered.
   function Is_Open (Item : Seer) return Boolean;

   --  The text a picture stands as in the prompt: the marker a model's own
   --  template writes where a picture goes, empty on a seer that is not
   --  open. A caller hands it to the template so that content given as
   --  parts renders with the picture where it stands.
   --
   --  @param Item Seer to inspect.
   --  @return The marker text, or "" where there is none.
   function Picture_Marker (Item : Seer) return String;

   --  The text a video slot stands as, as Picture_Marker is for a picture.
   --
   --  @param Item Seer to inspect.
   --  @return The marker text, or "" where there is none.
   function Video_Marker (Item : Seer) return String;

   --  Whether a list of parts names a picture or a video: a part of type
   --  image or image_url with a path or url, or of type video with a path.
   --
   --  @param Parts The parts, as one JSON list.
   --  @return True when at least one is named.
   function Names_A_Picture (Parts : String) return Boolean;

   --  Encode every picture the conversation names beyond the ones the set
   --  holds, in the conversation's order, and add their rows to the set.
   --
   --  @param Item Open seer.
   --  @param Messages The conversation.
   --  @param Into The picture set, extended.
   --  @param Team The pool to encode on, or null for the calling task.
   --  @param Crops Whether to pan and scan: cut a wide or tall picture
   --    into crops shown after the whole.
   --  @param Cancel Stop request, or null.
   --  @param Reporter Called after each picture, or null: with
   --    @param Index its number, @param Total the total named,
   --    @param Rows the rows it took, crops included, and
   --    @param Milliseconds the milliseconds it took.
   --  @param Status Success, IO_Open_Failed, IO_Image_Unreadable,
   --    Memory_Allocation_Failed, Generation_Cancelled,
   --    CLI_Option_Out_Of_Range past Max_Pictures or Max_Slots, or
   --    Arch_Unsupported_Feature for a video shown to a projector that
   --    reads none.
   procedure Gather
     (Item     : in out Seer;
      Messages : Model_Runner.Conversation.History;
      Into     : in out Model_Runner.Generation.Picture_Set;
      Team     : Model_Runner.Backend.CPU.Pool_Reference;
      Crops    : Boolean := False;
      Cancel   : Model_Runner.Cancellation.Token_Reference := null;
      Reporter : access procedure
        (Index, Total : Positive; Rows, Milliseconds : Natural) := null;
      Status   : out Model_Runner.Errors.Error_Info);

   --  Release a picture set's rows and forget its pictures.
   --
   --  @param Item The set.
   procedure Release (Item : in out Model_Runner.Generation.Picture_Set);

private

   type Seer is limited record
      Eyes   : Model_Runner.Vision.Encoder;
      Ready  : Boolean := False;
      Width  : Natural := 0;
      --  Whether the projector is MiniCPM-V's resampler, which frames a
      --  picture with <image> and </image> and shows a large one as an
      --  overview fit to the encoder's side and a grid of slices, each
      --  between <slice> and </slice>, a line break after each grid row.
      Resampler : Boolean := False;
      Slice_Marker, Slice_Closer : Model_Runner.Tokenizer.Token_Id :=
        Model_Runner.Tokenizer.No_Token;
      Slice_Marker_Text, Slice_Row_End : Model_Runner.Text.Bounded :=
        Model_Runner.Text.Empty;
      --  Whether a video's frames are shown as pictures (MiniCPM-V), each
      --  behind the picture marker, rather than as a video reader's slots.
      Video_Frames : Boolean := False;
      Marker, Soft, Closer : Model_Runner.Tokenizer.Token_Id :=
        Model_Runner.Tokenizer.No_Token;
      Keeps_Marker : Boolean := True;
      Marker_Text, Before, After : Model_Runner.Text.Bounded :=
        Model_Runner.Text.Empty;
      Lead, Bridge, Gap : Model_Runner.Text.Bounded :=
        Model_Runner.Text.Empty;

      --  The video's marker and its text, and the opener and closer a
      --  slot is set between, where the projector reads video.
      Video_Marker : Model_Runner.Tokenizer.Token_Id :=
        Model_Runner.Tokenizer.No_Token;
      Video_Text, Video_Open, Video_Close : Model_Runner.Text.Bounded :=
        Model_Runner.Text.Empty;
   end record;

end Model_Runner.CLI.Pictures;
