--  Expected values recorded from a trusted reference runtime.
--
--  A reference runtime is a second, already-trusted inference program -- for
--  example llama.cpp or a transformers script. It is never linked into
--  model_runner and never called by it: delegating inference to another
--  runtime is exactly what this project does not do. It is run once, by hand,
--  against the same model file, and what it produced is written down here so
--  that a later run can be compared against it without the reference being
--  present.
--
--  File format. One directive per line; blank lines and lines beginning with
--  '#' are ignored. Directives may appear in any order.
--
--     runtime NAME AND VERSION      what produced these values, for provenance
--     model NAME                    which model file they came from
--     prompt TEXT                   the prompt that was used, verbatim
--     tokens N N N ...              the reference tokenization of that prompt
--     greedy N N N ...              the token identifiers greedy decoding gave
--     greedy_text TEXT              the text greedy decoding produced, with
--                                   backslash-n and backslash-t escapes
--     logit INDEX VALUE             one expected logit for the first position
--     pooling mean|cls|last         how the reference reduced the states
--     embd INDEX VALUE              one component of the pooled, unit-length
--                                   embedding the reference produced
--     tolerance VALUE               absolute tolerance for the comparison
--
--  Only the directives that are present are checked, so a file recording just
--  the tokenization is a valid and useful expectation.
--
--  Provenance. The runtime and model directives are required for a file to be
--  accepted: an expectation whose origin is unrecorded is not evidence.
--
--  Task safety: a file is read by one task.
package Expectations is

   Max_Tokens : constant := 4096;
   Max_Logits : constant := 256;

   --  Components of a pooled embedding a reference runtime produced. Wide
   --  enough for the models this is used on -- 384 and 768 -- because what
   --  is compared is the whole vector rather than a sample of it: a cosine
   --  taken over part of a vector says nothing about the rest, and the
   --  faults this comparison exists to catch moved every component.
   Max_Components : constant := 1024;

   type Token_List is array (1 .. Max_Tokens) of Integer;

   type Logit_Entry is record
      Index : Natural := 0;
      Value : Long_Float := 0.0;
   end record;

   type Logit_List is array (1 .. Max_Logits) of Logit_Entry;

   type Component_List is array (1 .. Max_Components) of Long_Float;

   --  How the reference reduced a text's states to one vector.
   type Pooling_Kind is (Pool_Mean, Pool_Cls, Pool_Last);

   Max_Text : constant := 4096;

   --  What a reference runtime recorded.
   type Recording is record
      Valid         : Boolean := False;
      Runtime       : String (1 .. 128) := [others => ' '];
      Runtime_Last  : Natural := 0;
      Model         : String (1 .. 256) := [others => ' '];
      Model_Last    : Natural := 0;
      Prompt        : String (1 .. Max_Text) := [others => ' '];
      Prompt_Last   : Natural := 0;
      Tokens        : Token_List := [others => 0];
      Tokens_Used   : Natural := 0;
      Has_Tokens    : Boolean := False;
      Greedy        : Token_List := [others => 0];
      Greedy_Used   : Natural := 0;
      Has_Greedy    : Boolean := False;
      Greedy_Text   : String (1 .. Max_Text) := [others => ' '];
      Greedy_Last   : Natural := 0;
      Has_Text      : Boolean := False;
      Logits        : Logit_List := [others => <>];
      Logits_Used   : Natural := 0;

      --  The pooled, unit-length embedding the reference produced, in
      --  order, and how it pooled. Held whole: this is the only comparison
      --  here that does not rest on a reading of an architecture made in
      --  this repository, so it is worth the four kilobytes.
      Embedding      : Component_List := [others => 0.0];
      Embedding_Used : Natural := 0;
      Has_Embedding  : Boolean := False;
      Pooling        : Pooling_Kind := Pool_Mean;

      Tolerance     : Long_Float := 1.0E-2;
      Problem       : String (1 .. 200) := [others => ' '];
      Problem_Last  : Natural := 0;
   end record;

   --  Read an expectation file.
   --
   --  @param Path File to read.
   --  @param Item Recording; Valid is False when the file is absent or
   --    malformed, with Problem naming the reason.
   procedure Load (Path : String; Item : out Recording);

   --  The prompt the reference used.
   --
   --  @param Item Recording to read.
   --  @return Prompt text.
   function Prompt_Text (Item : Recording) return String
   is (Item.Prompt (1 .. Item.Prompt_Last));

   --  The text greedy decoding produced.
   --
   --  @param Item Recording to read.
   --  @return Expected text.
   function Greedy_Text (Item : Recording) return String
   is (Item.Greedy_Text (1 .. Item.Greedy_Last));

   --  What produced the recording.
   --
   --  @param Item Recording to read.
   --  @return Runtime name and version.
   function Runtime_Text (Item : Recording) return String
   is (Item.Runtime (1 .. Item.Runtime_Last));

   --  Why a recording was rejected.
   --
   --  @param Item Recording to read.
   --  @return Problem description, or an empty string.
   function Problem_Text (Item : Recording) return String
   is (Item.Problem (1 .. Item.Problem_Last));

end Expectations;
