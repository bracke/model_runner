with Ada.Strings.Unbounded;

with Model_Runner.Errors;
with Model_Runner.Framework.Stores;

--  What was produced, kept and never changed.
--
--  An analysis, a report, a verification run's outcome: each is stored
--  once as a result and referred to afterwards by its identifier rather
--  than copied. The identifier is made from the content -- RES- and the
--  fingerprint of what the result says -- so storing the same result twice
--  stores it once, and a result can never be changed under its identifier:
--  a different content is a different identifier. A stored result whose
--  payload no longer matches the fingerprint it was stored with is
--  reported as damaged rather than returned.
--
--  A payload larger than Inline_Limit is not kept in the record: it is kept
--  beside the results, named by its own fingerprint, and read only when the
--  payload is asked for -- so listing, pruning and showing what a result is
--  do not read a build's megabytes of output.
package Model_Runner.Framework.Results is

   --  What a result is.
   type Result_Kind is
     (Analysis,
      Implementation,
      Verification,
      Diagnostic,
      Decision_Proposal,
      Task_Proposal,
      Impact_Report,
      Integration_Report,
      Child_Result,
      Context_Report,
      Bootstrap_Report);

   --  One result.
   type Result is record
      Id         : Ada.Strings.Unbounded.Unbounded_String;
      Kind       : Result_Kind := Analysis;
      Producer   : Ada.Strings.Unbounded.Unbounded_String;
      Created_At : Ada.Strings.Unbounded.Unbounded_String;
      Summary    : Ada.Strings.Unbounded.Unbounded_String;
      Payload    : Ada.Strings.Unbounded.Unbounded_String;
      Provenance : Ada.Strings.Unbounded.Unbounded_String;

      --  Identifiers of other results this one refers to, one per line.
      References : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  The largest payload a result's record holds itself.
   Inline_Limit : constant := 64 * 1024;

   --  The word a kind of result is stored as.
   --
   --  @param Kind The kind.
   --  @return Its word, as impact_report.
   function Kind_Word (Kind : Result_Kind) return String;

   --  The identifier a result's content is stored under.
   --
   --  @param Value The result; its Id and Created_At are not part of it.
   --  @return RES- and sixteen upper-case hexadecimal digits.
   function Identifier_Of (Value : Result) return String;

   --  Stage a result in a transaction, unless it is already stored.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Value The result; its Id and Created_At are set here.
   --  @param Status Framework_Result_Conflict when another content is
   --    stored under the same identifier.
   procedure Add
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Value  : in out Result;
      Status : out Model_Runner.Errors.Error_Info);

   --  Read a stored result.
   --
   --  @param Item The store.
   --  @param Id Its identifier.
   --  @param Value The result, when Status is a success.
   --  @param Status Framework_Not_Found when there is none,
   --    Framework_Integrity_Failed when its payload no longer matches its
   --    fingerprint, and a read or format failure otherwise.
   --  @param With_Payload Whether to read its payload; without it, a
   --    payload kept apart is not read, and Payload is empty for it.
   procedure Read
     (Item         : Stores.Store;
      Id           : String;
      Value        : out Result;
      Status       : out Model_Runner.Errors.Error_Info;
      With_Payload : Boolean := True);

   --  How large a result's payload is, read from its record alone.
   --
   --  @param Item The store.
   --  @param Id The result.
   --  @return Its length in bytes; zero when there is no such result.
   function Payload_Size (Item : Stores.Store; Id : String) return Natural;

   --  Let results go that the project keeps only for a while. What is
   --  required stays whatever its age -- verification evidence is not a
   --  result, and an agent's answers, children's results, proposals and
   --  reports are kept -- and what goes is what can go: the raw logs of
   --  checks, whose diagnostics the evidence keeps, after Raw_Log_Days,
   --  and the contexts kept for audit, which can be built again, after
   --  Context_Days; and what is only a cache -- an impact report, worked
   --  out again from the graph whenever it is asked for -- after
   --  Cache_Days. Zero keeps them.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Raw_Log_Days How old a raw log may grow.
   --  @param Context_Days How old a kept context may grow.
   --  @param Removed How many went.
   --  @param Cache_Days How old a cache-like result may grow.
   procedure Prune
     (Item         : Stores.Store;
      Change       : in out Stores.Transaction;
      Raw_Log_Days : Natural;
      Context_Days : Natural;
      Removed      : out Natural;
      Cache_Days   : Natural := 0);

   --  Remove the payloads kept apart that no result refers to any more:
   --  those of results pruned, and any a write left that was never
   --  committed. Run once what removed the results is committed.
   --
   --  @param Item The store.
   --  @param Removed How many went.
   procedure Collect_Payloads (Item : Stores.Store; Removed : out Natural);

end Model_Runner.Framework.Results;
