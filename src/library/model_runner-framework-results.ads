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
   procedure Read
     (Item   : Stores.Store;
      Id     : String;
      Value  : out Result;
      Status : out Model_Runner.Errors.Error_Info);

end Model_Runner.Framework.Results;
