private with Ada.Finalization;

with Model_Runner.Errors;

--  The tools a caller offers a model, and the calls the model writes back.
--
--  A model trained to call tools is told what there is in its prompt -- its
--  own chat template writes the definitions into a system block -- and
--  answers with a call written into its reply. Nothing here runs anything.
--  This program starts no process, opens no socket and loads no library, so
--  a tool call is text the model wrote and a tool result is text the caller
--  hands back; the loop closes outside this program or it does not close at
--  all. What this package is for is the two ends of it: reading the
--  definitions a caller offers, and reading the calls back out of what the
--  model produced.
--
--  Definitions are written back rather than passed through. A caller writes
--  a file with newlines and indentation in it; the implementation these
--  templates were written for holds a parsed object and prints it in one
--  spelling, and that spelling is what the model was trained on. So a
--  definition read here is parsed and written out again in that spelling --
--  no line breaks, a space after each colon and each comma, escapes decoded
--  to the characters they stand for -- and what the template emits is this
--  engine's text rather than the caller's file. A number is written back as
--  the file spells it: 1.50 stays 1.50, because rewriting it would mean
--  choosing a spelling for every number a file could hold, and a schema's
--  bounds are read by the model as text either way.
--
--  A call is read by the convention the template states. Qwen3 tells the
--  model to write each call as a JSON object between <tool_call> and
--  </tool_call>, and that is the convention this reads; a model that answers
--  in another one produces a reply with no calls in it rather than a wrong
--  call, and the reply itself is still the caller's to read.
--
--  Bounds. The number of definitions, the number of calls and the room all
--  of them take are fixed here rather than taken from a caller: these are
--  small things and a file that is not one is refused rather than fitted.
--
--  Task safety: a Definitions or a Calls value is owned by one task; both
--  are read-only once read.
package Model_Runner.Tools is

   --  Largest number of tools one caller may offer.
   Max_Definitions : constant := 64;

   --  Room every definition takes together, once written back.
   Max_Definition_Bytes : constant := 64 * 1024;

   --  Largest number of calls read out of one reply.
   Max_Calls : constant := 32;

   --  Room every call's name and arguments take together.
   Max_Call_Bytes : constant := 32 * 1024;

   --  The tools a caller offers. Release with Close, which is idempotent.
   type Definitions is tagged limited private;

   --  Read a list of tool definitions.
   --
   --  Text is a JSON array of objects, or one object where there is only
   --  one. Each object is written back in the one spelling described above,
   --  and each has to name the function it describes -- as "name" at its top
   --  level, or as the "name" of its "function" member, which is the shape
   --  callers usually write. A tool nobody can name is refused rather than
   --  offered, because a model calling it would produce a call the caller
   --  cannot match to anything.
   --
   --  @param Item Definitions to fill in; released first.
   --  @param Text The definitions, as JSON.
   --  @param Status Success, Tools_Invalid_JSON when the text is not JSON
   --    this can read, Tools_Not_An_Object when an entry is not an object,
   --    Tools_Missing_Name when an entry names no function, Tools_Too_Many
   --    or Tools_Too_Large.
   procedure Read
     (Item   : in out Definitions;
      Text   : String;
      Status : out Model_Runner.Errors.Error_Info);

   --  Release the definitions.
   --
   --  @param Item Definitions to release.
   procedure Close (Item : in out Definitions);

   --  How many tools are offered.
   --
   --  @param Item Definitions to inspect.
   --  @return Tool count; zero when nothing was read.
   function Count (Item : Definitions) return Natural;

   --  One tool, as the template writes it.
   --
   --  @param Item Definitions to inspect.
   --  @param Index Position in 1 .. Count.
   --  @return The definition as one line of JSON, or an empty string when
   --    the position is out of range.
   function Definition (Item : Definitions; Index : Positive) return String;

   --  The name of one tool.
   --
   --  @param Item Definitions to inspect.
   --  @param Index Position in 1 .. Count.
   --  @return The function name, or an empty string when the position is out
   --    of range.
   function Tool_Name (Item : Definitions; Index : Positive) return String;

   --  Whether a name is one of the tools offered.
   --
   --  @param Item Definitions to inspect.
   --  @param Called The name a model wrote.
   --  @return True when a tool of that name is offered.
   function Offers (Item : Definitions; Called : String) return Boolean;

   --  The calls read out of one reply. Release with Close, which is
   --  idempotent.
   type Calls is tagged limited private;

   --  Read every call a reply carries.
   --
   --  What lies between <tool_call> and </tool_call> is read as a JSON
   --  object naming the function and its arguments. The arguments are
   --  written back in the same spelling the definitions are, so what a
   --  caller reads here is a call and not a transcription.
   --
   --  A reply with no such block carries no calls and is not an error: a
   --  model asked a question it can answer itself answers it.
   --
   --  @param Item Calls to fill in; released first.
   --  @param Reply What the model produced.
   --  @param Status Success, Tools_Call_Malformed when a block is not a call
   --    this can read -- the calls read before it are kept -- Tools_Too_Many
   --    or Tools_Too_Large.
   procedure Read_Calls
     (Item   : in out Calls;
      Reply  : String;
      Status : out Model_Runner.Errors.Error_Info);

   --  Release the calls.
   --
   --  @param Item Calls to release.
   procedure Close (Item : in out Calls);

   --  How many calls the reply carried.
   --
   --  @param Item Calls to inspect.
   --  @return Call count.
   function Count (Item : Calls) return Natural;

   --  The name of one call.
   --
   --  @param Item Calls to inspect.
   --  @param Index Position in 1 .. Count.
   --  @return The function name the model wrote, or an empty string when the
   --    position is out of range.
   function Called (Item : Calls; Index : Positive) return String;

   --  The arguments of one call.
   --
   --  @param Item Calls to inspect.
   --  @param Index Position in 1 .. Count.
   --  @return The arguments as one line of JSON, or an empty string when the
   --    position is out of range.
   function Arguments (Item : Calls; Index : Positive) return String;

   --  Where the model stopped speaking and started calling.
   --
   --  A reply that asks for a tool is what the model said and then the
   --  blocks it wrote the calls in. What it said belongs in the turn's
   --  text and the calls belong beside it, because a history that keeps
   --  the blocks as text hands the model its own spelling back on the next
   --  turn rather than the one its template writes.
   --
   --  @param Reply What the model produced.
   --  @return The length of the spoken part, with the whitespace before the
   --    first block taken off; the whole reply when it called nothing.
   function Spoken_Length (Reply : String) return Natural;

   --  Write a value back in the spelling this engine uses.
   --
   --  Exposed because a template renders text this produced and a test has
   --  to be able to produce it too, and because a caller assembling a
   --  conversation by hand needs the same spelling the model was trained on.
   --
   --  @param Text A JSON value.
   --  @param Target Buffer receiving the value, written back.
   --  @param Last Number of bytes written; 0 on failure.
   --  @param Status Success, Tools_Invalid_JSON naming where the text stops
   --    being JSON, or Tools_Too_Large when the buffer is too small.
   procedure Rewrite
     (Text   : String;
      Target : out String;
      Last   : out Natural;
      Status : out Model_Runner.Errors.Error_Info);

private

   --  Where one entry's text and its name lie in the pool. Both are slices
   --  of the same storage, so a definition costs one copy and not two.
   type Span is record
      Offset : Natural := 0;
      Length : Natural := 0;
   end record;

   type Entry_Row is record
      Text : Span;
      Name : Span;
   end record;

   type Entry_Array is array (1 .. Max_Definitions) of Entry_Row;

   type Call_Row is record
      Name      : Span;
      Arguments : Span;
   end record;

   type Call_Array is array (1 .. Max_Calls) of Call_Row;

   type Storage_Access is access String;

   type Definitions is limited new Ada.Finalization.Limited_Controlled with
   record
      Rows    : Entry_Array := [others => <>];
      Used    : Natural := 0;
      Pool    : Storage_Access := null;
      Filled  : Natural := 0;
   end record;

   overriding procedure Finalize (Item : in out Definitions);

   type Calls is limited new Ada.Finalization.Limited_Controlled with record
      Rows   : Call_Array := [others => <>];
      Used   : Natural := 0;
      Pool   : Storage_Access := null;
      Filled : Natural := 0;
   end record;

   overriding procedure Finalize (Item : in out Calls);

end Model_Runner.Tools;
