with Interfaces;
with Model_Runner.Backend;
with Model_Runner.Bytes;
with Model_Runner.CLI.Options;
with Model_Runner.Errors;
with Model_Runner.Limits;
with Model_Runner.Llama;
with Model_Runner.Localization;
with Model_Runner.Presentation;

--  Command execution.
--
--  Execution works from the typed Command value alone. It never looks at a raw
--  argument string, so every option conflict has already been settled by the
--  parser and there is nothing left here to reinterpret.
--
--  Each command returns the process exit status through the centralized
--  mapping in Model_Runner.Errors, so the same condition always produces the
--  same status.
--
--  Task safety: one command runs at a time on the calling task.
package Model_Runner.CLI.Execute is

   --  Run a parsed command.
   --
   --  @param Item Typed command.
   --  @param Screen Console for application output and diagnostics.
   --  @param Catalog Resolved message catalog.
   --  @param Status Process exit status.
   procedure Dispatch
     (Item    : Model_Runner.CLI.Options.Command;
      Screen  : in out Model_Runner.Presentation.Console;
      Catalog : Model_Runner.Localization.Catalog;
      Status  : out Natural);

   --  Write bytes to a path, replacing whatever was there, a fixed chunk at
   --  a time so a payload of any size writes without a stack buffer sized to
   --  it. A saved context reaches many megabytes -- a copy of it onto the
   --  stack overflowed it -- which is why this is here to be driven by the
   --  suite with a payload larger than any fixture session.
   --
   --  @param Path Destination file.
   --  @param Data Bytes to write.
   --  @param Status Success, or the reason the write did not happen.
   --  @param Durable Whether the bytes are put on the device before the
   --    file takes its name; a cache the next run checks needs only the
   --    move.
   procedure Write_File
     (Path    : String;
      Data    : Model_Runner.Bytes.Byte_Array;
      Status  : out Model_Runner.Errors.Error_Info;
      Durable : Boolean := True);

   --  The backend run takes where none is named: the device where it opens
   --  and the model fits its budget, the processor otherwise -- the one
   --  decision, for a tool that measures what run does.
   --
   --  @param Model_Path The model, as run would be given it.
   --  @param Device_Memory The device budget named, 0 for the default.
   --  @param Screen Where run's notes about the choice go.
   --  @param Context_Size The context named, 0 for none: a dense model's
   --    room on the device is counted less it.
   --  @param Cache The precision the context is kept in.
   --  @param Paged False where --no-paged is named.
   --  @return The backend.
   function Unasked_Backend
     (Model_Path    : String;
      Device_Memory : Interfaces.Unsigned_64;
      Screen        : in out Model_Runner.Presentation.Console;
      Context_Size  : Natural := 0;
      Cache         : Model_Runner.Llama.Cache_Precision :=
        Model_Runner.Llama.Halved;
      Paged         : Boolean := True)
      return Model_Runner.Backend.Backend_Kind;

   --  The room on the device run leaves beside a model for the draft it was
   --  asked to draft with: the draft's file, which is about what its
   --  matrices take there. Nothing where none was named.
   --
   --  @param Draft_Path The draft model named, or empty.
   --  @return Bytes.
   function Draft_Room (Draft_Path : String) return Interfaces.Unsigned_64;

   --  The arithmetic run takes for a prepared model: the one named, or
   --  where none is named the one the model is measured to want -- Gemma
   --  2's mixed one -- for a tool that measures what run does.
   --
   --  @param Named The arithmetic named (f32, int8, mixed), or empty.
   --  @param Prepared The model, prepared.
   --  @return The arithmetic.
   function Unasked_Arithmetic
     (Named    : String;
      Prepared : Model_Runner.Llama.Model)
      return Model_Runner.Llama.Arithmetic_Mode;

   --  Tell the backends an arithmetic, as run does before its session
   --  opens: the processor's integer roles and the device's walks.
   --
   --  @param Mode The arithmetic.
   procedure Use_Arithmetic (Mode : Model_Runner.Llama.Arithmetic_Mode);

   --  The session limits run opens a session with: the memory limit named,
   --  or half the machine's -- what a context left to the model's own is
   --  halved until it fits.
   --
   --  @param Memory_Limit The limit named, or nought for none.
   --  @return The limits.
   function Unasked_Session_Bounds
     (Memory_Limit : Interfaces.Unsigned_64 := 0)
      return Model_Runner.Limits.Session_Limits;

   --  The weight layout run takes unasked: the panels on the processor
   --  where the whole model -- every shard of it -- fits them, the file's
   --  rows otherwise.
   --
   --  @param Model_Path The model, as run would be given it.
   --  @param Backend The backend the run is on.
   --  @param Memory_Limit The limit named, or nought for none.
   --  @return The layout.
   function Unasked_Layout
     (Model_Path   : String;
      Backend      : Model_Runner.Backend.Backend_Kind;
      Memory_Limit : Interfaces.Unsigned_64 := 0)
      return Model_Runner.Llama.Repack_Mode;

   --  Where run keeps a model's panels between loads; empty where caches
   --  are refused.
   --
   --  @param Model_Path The model, as run would be given it.
   --  @param No_Cache Whether caches are refused.
   --  @return The panel file, or empty.
   function Unasked_Panel_Cache
     (Model_Path : String;
      No_Cache   : Boolean := False) return String;

end Model_Runner.CLI.Execute;
