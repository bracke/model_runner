with Ada.Real_Time;
with Ada.Strings.Unbounded;

with Model_Runner.Cancellation;
with Model_Runner.Code_Health.Providers;
with Model_Runner.Errors;
with Model_Runner.Framework.Execution;
with Model_Runner.Framework.Stores;

--  Framework-backed provider process capability. The owning lifecycle keeps
--  the store and transaction alive; providers receive only Command_Runner.
package Model_Runner.Code_Health.Execution is

   package P renames Model_Runner.Code_Health.Providers;
   package X renames Model_Runner.Framework.Execution;
   package S renames Model_Runner.Framework.Stores;

   type Store_Reference is access all S.Store;
   type Transaction_Reference is access all S.Transaction;

   type Framework_Runner is limited new P.Command_Runner with private;

   procedure Initialize
     (Self   : in out Framework_Runner;
      Store  : not null Store_Reference;
      Change : not null Transaction_Reference;
      Base   : String := "");

   overriding procedure Run
     (Self      : in out Framework_Runner;
      Rules     : X.Policy;
      Command   : String;
      Directory : String;
      Deadline  : Ada.Real_Time.Time;
      Cancel    : Model_Runner.Cancellation.Token_Reference;
      Result    : out X.Outcome;
      Status    : out Model_Runner.Errors.Error_Info);

private

   type Framework_Runner is limited new P.Command_Runner with record
      Store  : Store_Reference;
      Change : Transaction_Reference;
      Base   : Ada.Strings.Unbounded.Unbounded_String;
   end record;

end Model_Runner.Code_Health.Execution;
