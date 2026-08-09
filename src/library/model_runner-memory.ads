with Interfaces;

with Model_Runner.Errors;
with Model_Runner.Limits;

--  Memory accounting and planning.
--
--  Every large allocation is attributed to a category, checked against the
--  configured limits before it is requested, and recorded so that peak use can
--  be reported. The account is an explicit object owned by a preparation or a
--  session; there is no process-wide accounting state.
--
--  Mapped bytes are tracked separately from allocated bytes and are never
--  presented as resident memory, because a read-only mapping of a model file
--  costs address space rather than physical pages.
--
--  Task safety: an account is updated by the task that owns the preparation or
--  session. Workers do not allocate.
package Model_Runner.Memory is

   subtype U64 is Interfaces.Unsigned_64;

   --  What an allocation is for. Reported in statistics and in memory-limit
   --  diagnostics so that a user can tell which part of the plan is too large.
   --  Where memory goes.
   --
   --  Every category here is charged by something. A category nothing
   --  charges is a line of a report reading zero for memory the program is
   --  holding, and a limit that does not count it -- nine of eleven were in
   --  that position, including the KV cache, which is the largest thing a
   --  session allocates.
   --
   --  Temporary_Workspace was removed rather than charged. The buffers it
   --  named are allocated and released within one call, so charging one
   --  would record a number that is true for the length of a statement, and
   --  the limits that size those buffers already bound them.
   type Category is
     (Model_Weights,
      Converted_Weights,
      KV_Cache,
      Activations,
      Logits,
      Sampling_Workspace,
      Token_Buffers,
      Template_Buffers,
      Metadata_Storage,
      Tokenizer_Storage);

   type Category_Totals is array (Category) of U64;

   --  Running totals for one owner.
   type Account is record
      Requested   : U64 := 0;
      Aligned     : U64 := 0;
      Current     : U64 := 0;
      Peak        : U64 := 0;
      Released    : U64 := 0;
      Mapped      : U64 := 0;
      Converted   : U64 := 0;
      By_Category : Category_Totals := [others => 0];
      Limits      : Model_Runner.Limits.Model_Limits :=
        Model_Runner.Limits.Default_Model_Limits;
      Budget      : U64 := 0;
   end record;

   --  Prepare an account for a given limit set and total budget.
   --
   --  @param Item Account to initialize.
   --  @param Model_Limit Limits that bound individual allocations.
   --  @param Budget Total resident budget in bytes; 0 means unlimited.
   procedure Initialize
     (Item        : out Account;
      Model_Limit : Model_Runner.Limits.Model_Limits;
      Budget      : U64 := 0);

   --  Check that an allocation is permitted before requesting it.
   --
   --  Checking first turns a plan that cannot fit into a structured
   --  Memory_Limit_Exceeded before any allocator is called. Real allocation
   --  failure is still handled, because a limit check cannot predict the state
   --  of the host heap.
   --
   --  @param Item Account to check against.
   --  @param Kind Allocation category.
   --  @param Bytes Requested size.
   --  @param Status Success, or Memory_Limit_Exceeded with the offending
   --    category and size.
   procedure Check_Allocation
     (Item   : Account;
      Kind   : Category;
      Bytes  : U64;
      Status : out Model_Runner.Errors.Error_Info);

   --  Record a successful allocation.
   --
   --  @param Item Account to update.
   --  @param Kind Allocation category.
   --  @param Bytes Size actually allocated.
   procedure Record_Allocation
     (Item  : in out Account;
      Kind  : Category;
      Bytes : U64);

   --  Record a release.
   --
   --  @param Item Account to update.
   --  @param Kind Allocation category.
   --  @param Bytes Size released.
   procedure Record_Release
     (Item  : in out Account;
      Kind  : Category;
      Bytes : U64);

   --  Record bytes made visible through a read-only file mapping.
   --
   --  @param Item Account to update.
   --  @param Bytes Mapped size.
   procedure Record_Mapping (Item : in out Account; Bytes : U64);

   --  Record bytes produced by converting or repacking model tensors.
   --
   --  @param Item Account to update.
   --  @param Bytes Converted size.
   procedure Record_Conversion (Item : in out Account; Bytes : U64);

   ---------------------------------------------------------------------------
   --  Planning
   ---------------------------------------------------------------------------

   --  An estimate produced before any large allocation is requested.
   --
   --  Every component is derived with checked arithmetic. Overflow is reported
   --  as Memory_Plan_Overflow rather than producing a wrapped total.
   type Plan is record
      File_Backed_Bytes  : U64 := 0;
      Copied_Bytes       : U64 := 0;
      Converted_Bytes    : U64 := 0;
      Backend_Bytes      : U64 := 0;
      Worker_Bytes       : U64 := 0;
      Conversion_Overlap : U64 := 0;
      Alignment_Overhead : U64 := 0;
      Safety_Margin      : U64 := 0;
      Total_Resident     : U64 := 0;
      Valid              : Boolean := False;
   end record;

   --  A session's estimate, produced before the session is created.
   type Session_Plan is record
      KV_Cache_Bytes       : U64 := 0;
      Activation_Bytes     : U64 := 0;
      Batch_Bytes          : U64 := 0;
      Logits_Bytes         : U64 := 0;
      Sampling_Bytes       : U64 := 0;
      Token_History_Bytes  : U64 := 0;
      Decoder_Bytes        : U64 := 0;
      Stop_Bytes           : U64 := 0;
      Rendering_Bytes      : U64 := 0;
      Safety_Margin        : U64 := 0;
      Total_Resident       : U64 := 0;
      Valid                : Boolean := False;
   end record;

   --  Fraction of the computed total added as a safety margin, in percent.
   Safety_Margin_Percent : constant := 5;

   --  Total what a model will actually hold in memory, and set Total_Resident.
   --
   --  File_Backed_Bytes is deliberately not part of the total. A mapped model
   --  lives in the operating system's pages, and counting it as resident would
   --  report a run as needing a gigabyte it never asks the heap for. What is
   --  counted is what this program allocates, plus Safety_Margin_Percent of
   --  it, which is written back into Safety_Margin.
   --
   --  @param Item Plan whose components are already filled in.
   --  @param Status Success, or Memory_Plan_Overflow.
   procedure Finalize_Plan
     (Item   : in out Plan;
      Status : out Model_Runner.Errors.Error_Info);

   --  Total what a session will hold in memory, and set Total_Resident.
   --
   --  As with Finalize_Plan: what this program allocates, plus
   --  Safety_Margin_Percent of it.
   --
   --  @param Item Plan whose components are already filled in.
   --  @param Status Success, or Memory_Plan_Overflow.
   procedure Finalize_Session_Plan
     (Item   : in out Session_Plan;
      Status : out Model_Runner.Errors.Error_Info);

   --  Stable machine-readable name of a category, used in diagnostics and in
   --  statistics field names. Never localized.
   --
   --  @param Item Category to name.
   --  @return Lower-case identifier such as "kv_cache".
   function Category_Name (Item : Category) return String;

end Model_Runner.Memory;
