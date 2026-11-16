with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Model_Runner.Errors;

--  Immutable workspace snapshots and normalized differences between them.
--  Reconciliation reads the actual tree; tool arguments and tool output are
--  never treated as a change manifest.
package Model_Runner.Code_Health.Changes is

   type Change_Kind is
     (Created,
      Modified,
      Deleted,
      Renamed);

   type Source_Kind is
     (Direct_Tool,
      External_Command,
      Delegated_Agent,
      Reconciliation);

   type File_Change is record
      Kind        : Change_Kind := Modified;
      Source      : Source_Kind := Reconciliation;
      Path        : Ada.Strings.Unbounded.Unbounded_String;
      Old_Path    : Ada.Strings.Unbounded.Unbounded_String;
      Before_Hash : Ada.Strings.Unbounded.Unbounded_String;
      After_Hash  : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   type Change_Set is private;
   type Snapshot is private;

   --  @param Changes Change set to update.
   --  @param Item Observed file change.
   procedure Record_Change
     (Changes : in out Change_Set;
      Item    : File_Change);

   --  @param Changes Change set to coalesce and identify.
   procedure Normalize (Changes : in out Change_Set);

   --  Forget all accumulated changes and their identifier.
   --  @param Changes Change set to clear.
   procedure Clear (Changes : in out Change_Set);

   --  @param From Change set.
   --  @return Number of normalized changes.
   function Length (From : Change_Set) return Natural;

   --  @param From Change set.
   --  @param Index One-based index.
   --  @return File change.
   function Element
     (From  : Change_Set;
      Index : Positive) return File_Change;

   --  @param From Change set.
   --  @return Immutable change-set identifier.
   function Identifier (From : Change_Set) return String;

   --  Capture every ordinary project file except version-control, harness
   --  state and conventional build/dependency output.  Unsupported files
   --  remain visible through Skipped_Count and Skipped_At.
   --  @param Project_Root Project or workspace root.
   --  @param Result Captured immutable snapshot.
   --  @param Status Success or filesystem/confinement failure.
   procedure Capture
     (Project_Root : String;
      Result       : out Snapshot;
      Status       : out Model_Runner.Errors.Error_Info);

   --  @param From Snapshot.
   --  @return Immutable tree identifier.
   function Identifier (From : Snapshot) return String;

   --  @param From Snapshot.
   --  @return Canonical project root.
   function Root (From : Snapshot) return String;

   --  @param From Snapshot.
   --  @return Number of ordinary captured files.
   function File_Count (From : Snapshot) return Natural;

   --  @param From Snapshot.
   --  @param Index One-based file index.
   --  @return Normalized project-relative path.
   function File_At (From : Snapshot; Index : Positive) return String;

   --  @param From Snapshot.
   --  @return Number of unsupported or excluded ordinary files reported.
   function Skipped_Count (From : Snapshot) return Natural;

   --  A skipped path and its reason, separated by a colon.
   --  @param From Snapshot.
   --  @param Index One-based skipped-file index.
   --  @return Path and reason.
   function Skipped_At
     (From  : Snapshot;
      Index : Positive) return String;

   --  @param Before Earlier immutable snapshot.
   --  @param After Later immutable snapshot.
   --  @param Source Mutation source.
   --  @param Result Normalized changes.
   --  @param Status Success or reconciliation failure.
   procedure Reconcile
     (Before : Snapshot;
      After  : Snapshot;
      Source : Source_Kind;
      Result : out Change_Set;
      Status : out Model_Runner.Errors.Error_Info);

private

   type File_State is record
      Path : Ada.Strings.Unbounded.Unbounded_String;
      Hash : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   package File_State_Lists is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => File_State);

   package File_Change_Lists is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => File_Change);

   type Snapshot is record
      Project_Root : Ada.Strings.Unbounded.Unbounded_String;
      Files        : File_State_Lists.Vector;
      Skipped      : String_Lists.Vector;
      Id           : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   type Change_Set is record
      Items : File_Change_Lists.Vector;
      Id    : Ada.Strings.Unbounded.Unbounded_String;
   end record;

end Model_Runner.Code_Health.Changes;
