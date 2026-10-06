with Model_Runner.GGUF.Containers;
with Ada.Strings.Unbounded;
with Ada.Unchecked_Deallocation;
with Model_Runner.Byte_Sources.Files;
with Model_Runner.GGUF.Shards;
with Model_Runner.Backend.CPU;
with Model_Runner.Conversation;
with Model_Runner.GGUF;
with Model_Runner.Generation;
with Model_Runner.Limits;
with Model_Runner.Llama;
with Model_Runner.Numerics;
with Model_Runner.Tensors;
with Model_Runner.Text;
with Model_Runner.Tokenizer;

--  Part of the command line's execution: see Model_Runner.CLI.Execute.
private package Model_Runner.CLI.Execute.Support is

   --  The packages the command code names, by the short names it uses.

   package Conv renames Model_Runner.Conversation;
   package E renames Model_Runner.Errors;
   package Files renames Model_Runner.Byte_Sources.Files;
   package Shards renames Model_Runner.GGUF.Shards;
   package G renames Model_Runner.GGUF;
   package Gen renames Model_Runner.Generation;
   package Containers renames Model_Runner.GGUF.Containers;
   package L renames Model_Runner.Llama;
   package Loc renames Model_Runner.Localization;
   package N renames Model_Runner.Numerics;

   procedure Free_Reals is
     new Ada.Unchecked_Deallocation
       (Model_Runner.Numerics.Real_Array,
        Model_Runner.Tensors.Real_Array_Access);
   package Opt renames Model_Runner.CLI.Options;

   package Pres renames Model_Runner.Presentation;
   package Workers_CPU renames Model_Runner.Backend.CPU;
   package T renames Model_Runner.Text;
   package US renames Ada.Strings.Unbounded;
   package Vocab renames Model_Runner.Tokenizer;

   procedure Free_Text is
     new Ada.Unchecked_Deallocation (String, Opt.Text_Access);

   --  A string as a JSON string body: the quote, the backslash and the
   --  control characters become escapes, so a tool argument or result drops
   --  into a trace as valid JSON.
   --
   --  @param S The text.
   --  @return Its JSON string body, without the quotes.
   function JSON_Escape (S : String) return String;

   --  Read a whole prompt or input file, no larger than a bound.
   --
   --  @param Path The file.
   --  @param Limit The most bytes it may hold.
   --  @param Result Its text, allocated; null on failure.
   --  @param Status A failure naming the file, or success.
   procedure Read_File
     (Path   : String;
      Limit  : Natural;
      Result : out Opt.Text_Access;
      Status : out E.Error_Info);

   --  Read standard input whole, no larger than a bound. Name is what the
   --  failure says it was reading -- the localized name of standard input --
   --  since the message is written for a file.
   --
   --  @param Name What to call standard input in a failure.
   --  @param Limit The most bytes it may hold.
   --  @param Result Its text, allocated; null on failure.
   --  @param Status A failure, or success.
   procedure Read_Standard_Input
     (Name   : String;
      Limit  : Natural;
      Result : out Opt.Text_Access;
      Status : out E.Error_Info);

   --  The model limits a command asks for.
   --
   --  @param Item The command.
   --  @return The limits.
   function Model_Bounds
     (Item : Opt.Command) return Model_Runner.Limits.Model_Limits;

   --  The session limits a command asks for, refused where the context it
   --  asks for would not fit beside the model.
   --
   --  @param Item The command.
   --  @return The limits.
   function Session_Bounds
     (Item : Opt.Command) return Model_Runner.Limits.Session_Limits;

   --  Whether a session keeps its context in pages: on the device unless
   --  --no-paged says otherwise, off on the processor unless --paged asks.
   --
   --  @param Item The command.
   --  @return True to page the context.
   function Session_Paging (Item : Opt.Command) return Boolean;

   --  Say how much of the device a session left free, where it opened on
   --  the device and the device does not hold it whole.
   --
   --  @param Screen Where notes go.
   --  @param Session Session just opened.
   procedure Say_Device_Room
     (Screen  : in out Pres.Console;
      Session : L.Session);

   --  The arithmetic a run uses: the one the command names, or the one
   --  the model is measured to want.
   --
   --  @param Item The command.
   --  @param Prepared The model.
   --  @return The arithmetic mode.
   function Chosen_Arithmetic
     (Item : Opt.Command; Prepared : L.Model) return L.Arithmetic_Mode;

   --  How many processor workers a command runs with.
   --
   --  @param Item The command.
   --  @return The count, at least one.
   function Selected_Workers (Item : Opt.Command) return Positive;

   --  What the command asks of the rotation, over what the file states;
   --  empty and zero are unasked.
   --
   --  @param Item The command.
   --  @return The request.
   function Asked_Rotation (Item : Opt.Command) return L.Rotary_Request;

   --  The command with its backend decided where it named none: the
   --  device where it opens and the model fits its budget, the processor
   --  otherwise.
   --
   --  @param Item The command.
   --  @param Screen Where notes go.
   --  @return The command as it runs.
   function Resolved_Backend
     (Item   : Opt.Command;
      Screen : in out Pres.Console) return Opt.Command;

   --  The command with the processor's panel layout asked for unasked,
   --  where the run is on the processor and the model is one panels cover.
   --
   --  @param Item The command.
   --  @return The command as it runs.
   function With_Panels (Item : Opt.Command) return Opt.Command;

end Model_Runner.CLI.Execute.Support;
