with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Model_Runner.Code_Health.Baselines;
with Model_Runner.Code_Health.Providers;
with Model_Runner.Errors;
with Model_Runner.Framework.Stores;
with Model_Runner.Framework.Verification;

--  Revision-bound Code Health assessments in the framework evidence store.
package Model_Runner.Code_Health.Evidence is

   type Assessment_Context is record
      Project                   : Ada.Strings.Unbounded.Unbounded_String;
      Task_Id                   : Ada.Strings.Unbounded.Unbounded_String;
      Generation                : Natural := 0;
      Agent_Id                  : Ada.Strings.Unbounded.Unbounded_String;
      Invocation_Id             : Ada.Strings.Unbounded.Unbounded_String;
      Workspace                 : Ada.Strings.Unbounded.Unbounded_String;
      Snapshot                  : Ada.Strings.Unbounded.Unbounded_String;
      Configuration_Fingerprint : Ada.Strings.Unbounded.Unbounded_String;
      Toolchain_Fingerprint     : Ada.Strings.Unbounded.Unbounded_String;
      Environment_Fingerprint   : Ada.Strings.Unbounded.Unbounded_String;
      Profile                   : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   package Analysis_Result_Lists is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Providers.Analysis_Result,
      "="          => Providers."=");

   type Assessment is private;

   --  @param Context Exact task, workspace and fingerprint context.
   --  @param Level Analysis level.
   --  @param State Resulting health state.
   --  @param Results Individual provider results.
   --  @param Classifications Baseline classifications.
   --  @param Baseline_Id Baseline evidence identity, or empty.
   --  @param Cache_Key Complete reuse key, or empty.
   --  @param Result New in-memory assessment.
   --  @param Status Success or structural failure.
   procedure Create
     (Context         : Assessment_Context;
      Level           : Check_Level;
      State           : Health_State;
      Results         : Analysis_Result_Lists.Vector;
      Classifications : Baselines.Classification_List;
      Baseline_Id     : String;
      Cache_Key       : String;
      Result          : out Assessment;
      Status          : out Model_Runner.Errors.Error_Info);

   --  Stage a new immutable CH record. An assessment already carrying an
   --  identifier cannot be written again through this API.
   --  @param Item Project store.
   --  @param Change Transaction receiving the record.
   --  @param Value Assessment to identify and persist.
   --  @param Status Success or persistence conflict.
   procedure Keep
     (Item     : Model_Runner.Framework.Stores.Store;
      Change   : in out Model_Runner.Framework.Stores.Transaction;
      Value    : in out Assessment;
      Status   : out Model_Runner.Errors.Error_Info);

   --  @param Item Project store.
   --  @param Id Assessment identity.
   --  @param Value Restored assessment.
   --  @param Status Success or read/validation failure.
   procedure Read
     (Item     : Model_Runner.Framework.Stores.Store;
      Id       : String;
      Value    : out Assessment;
      Status   : out Model_Runner.Errors.Error_Info);

   --  @param Item Assessment.
   --  @return Immutable identity.
   function Identifier (Item : Assessment) return String;
   --  @param Item Assessment.
   --  @return Captured context.
   function Context_Of (Item : Assessment) return Assessment_Context;
   --  @param Item Assessment.
   --  @return Analysis level.
   function Level_Of (Item : Assessment) return Check_Level;
   --  @param Item Assessment.
   --  @return Health state.
   function State_Of (Item : Assessment) return Health_State;
   --  @param Item Assessment.
   --  @return Provider results.
   function Results_Of (Item : Assessment) return Analysis_Result_Lists.Vector;
   --  @param Item Assessment.
   --  @return Finding classifications.
   function Classifications_Of (Item : Assessment) return Baselines.Classification_List;
   --  @param Item Assessment.
   --  @return Baseline identity, or empty.
   function Baseline_Of (Item : Assessment) return String;
   --  @param Item Assessment.
   --  @return Complete reuse key, or empty.
   function Cache_Key_Of (Item : Assessment) return String;

   --  The complete deterministic reuse key required by CH-001.
   --  @param Provider_Id Provider identity.
   --  @param Provider_Version Provider version.
   --  @param Check_Id Check identity.
   --  @param Input_Snapshot Immutable source identity.
   --  @param Configuration_Fingerprint Configuration fingerprint.
   --  @param Toolchain_Fingerprint Toolchain fingerprint.
   --  @param Environment_Fingerprint Analysis environment fingerprint.
   --  @return Stable complete cache key.
   function Make_Cache_Key
     (Provider_Id              : String;
      Provider_Version         : String;
      Check_Id                 : String;
      Input_Snapshot           : String;
      Configuration_Fingerprint : String;
      Toolchain_Fingerprint    : String;
      Environment_Fingerprint  : String) return String;

   --  Applicability uses the framework's existing vocabulary. Unlike full
   --  verification, the caller supplies the exact workspace snapshot and
   --  Code Health policy/tool bindings being judged.
   --  @param Item Project store.
   --  @param Id Assessment identity.
   --  @param Current Current context.
   --  @return Framework applicability report.
   function Applicable
     (Item     : Model_Runner.Framework.Stores.Store;
      Id       : String;
      Current  : Assessment_Context) return Model_Runner.Framework.Verification.Applicability_Report;

   --  Find a reusable completed assessment. Task, generation and workspace
   --  are part of applicability, so parallel work cannot exchange evidence.
   --  @param Item Project store.
   --  @param Cache_Key Complete reuse key.
   --  @param Current Current context.
   --  @return Reusable assessment identity, or empty.
   function Find_Reusable
     (Item      : Model_Runner.Framework.Stores.Store;
      Cache_Key : String;
      Current   : Assessment_Context) return String;

private

   type Assessment is record
      Id              : Ada.Strings.Unbounded.Unbounded_String;
      Context         : Assessment_Context;
      Level           : Check_Level := Fast;
      State           : Health_State := Not_Started;
      Results         : Analysis_Result_Lists.Vector;
      Classifications : Baselines.Classification_List;
      Baseline        : Ada.Strings.Unbounded.Unbounded_String;
      Cache_Key       : Ada.Strings.Unbounded.Unbounded_String;
   end record;

end Model_Runner.Code_Health.Evidence;
