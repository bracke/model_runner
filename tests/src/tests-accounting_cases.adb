with AUnit.Assertions;

with Interfaces;

with Model_Runner.Clocks;
with Model_Runner.Errors;
with Model_Runner.Limits;
with Model_Runner.Memory;

package body Tests.Accounting_Cases is

   use AUnit.Assertions;
   use type Interfaces.Unsigned_64;
   use type Model_Runner.Errors.Error_Code;

   package E renames Model_Runner.Errors;
   package M renames Model_Runner.Memory;

   subtype U64 is Interfaces.Unsigned_64;

   --  An allocation beyond the budget is refused before any allocator runs.
   procedure Over_Budget_Is_Refused
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Account : M.Account;
      Status  : E.Error_Info;
   begin
      M.Initialize
        (Account, Model_Runner.Limits.Default_Model_Limits, Budget => 1024);

      M.Check_Allocation (Account, M.KV_Cache, 512, Status);
      Assert (E.Is_Ok (Status), "an allocation inside the budget was refused");
      M.Record_Allocation (Account, M.KV_Cache, 512);

      --  The second request fits on its own and not alongside the first.
      M.Check_Allocation (Account, M.KV_Cache, 1024, Status);
      Assert (Status.Code = E.Memory_Limit_Exceeded,
              "an allocation past the budget was permitted");

      M.Check_Allocation (Account, M.KV_Cache, 512, Status);
      Assert (E.Is_Ok (Status),
              "an allocation that exactly fills the budget was refused");
   end Over_Budget_Is_Refused;

   --  Totals follow allocation and release, and the peak does not fall.
   procedure Totals_Follow_Allocation
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Account : M.Account;
   begin
      M.Initialize (Account, Model_Runner.Limits.Default_Model_Limits);

      M.Record_Allocation (Account, M.Activations, 400);
      M.Record_Allocation (Account, M.Logits, 600);
      Assert (Account.Current = 1000, "current total is wrong");
      Assert (Account.Peak = 1000, "peak did not follow the allocations");

      M.Record_Release (Account, M.Activations, 400);
      Assert (Account.Current = 600, "a release did not reduce the current");

      --  A peak is a high-water mark. Allocating again after a release must
      --  not pull it down to the new current: a report that did would
      --  understate what the run actually needed, which is the one number
      --  anybody reads it for. Asserting only that a release leaves the peak
      --  alone is too weak -- releases never touch it.
      M.Record_Allocation (Account, M.Activations, 100);
      Assert (Account.Current = 700, "the current is wrong after reallocating");
      Assert (Account.Peak = 1000,
              "the peak followed the current downwards:"
              & U64'Image (Account.Peak));

      Assert (Account.By_Category (M.Logits) = 600,
              "the category total is wrong");
   end Totals_Follow_Allocation;

   --  Mapped bytes are not allocated bytes.
   procedure Mapping_Is_Counted_Apart
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Account : M.Account;
   begin
      M.Initialize (Account, Model_Runner.Limits.Default_Model_Limits);

      M.Record_Mapping (Account, 1_000_000);

      --  A mapped file is the operating system's pages, not this program's
      --  heap. Counting it as allocated would make a memory-mapped run look
      --  as though it had copied the model.
      Assert (Account.Mapped = 1_000_000, "mapped bytes were not recorded");
      Assert (Account.Current = 0,
              "a mapping was counted as an allocation");
      Assert (Account.Peak = 0, "a mapping raised the allocation peak");
   end Mapping_Is_Counted_Apart;

   --  A plan whose parts overflow is refused rather than wrapping.
   procedure Plan_Overflow_Is_Refused
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Item   : M.Plan;
      Status : E.Error_Info;
   begin
      --  What a model file claiming impossible dimensions produces. Summed
      --  without care these wrap to a small number and the run proceeds as
      --  though the model were tiny.
      Item.File_Backed_Bytes := U64'Last / 2;
      Item.Copied_Bytes := U64'Last / 2;
      Item.Converted_Bytes := U64'Last / 2;

      M.Finalize_Plan (Item, Status);
      Assert (Status.Code = E.Memory_Plan_Overflow,
              "a plan that cannot be represented was accepted");
      Assert (not Item.Valid, "an overflowing plan was marked valid");
   end Plan_Overflow_Is_Refused;

   --  A plan totals the memory that will actually be resident.
   procedure Plan_Sums_Its_Parts
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Item   : M.Plan;
      Status : E.Error_Info;
   begin
      Item.File_Backed_Bytes := 1000;
      Item.Copied_Bytes := 200;
      Item.Backend_Bytes := 30;
      Item.Alignment_Overhead := 4;

      M.Finalize_Plan (Item, Status);
      Assert (E.Is_Ok (Status), "a representable plan was refused");
      Assert (Item.Valid, "a representable plan was not marked valid");

      --  File-backed bytes are deliberately not in the total: a mapped model
      --  is the operating system's pages, and counting it as resident would
      --  say a run needs a gigabyte of memory it never asks the heap for.
      --  On top of what is resident sits a fixed margin.
      declare
         Resident : constant U64 := 200 + 30 + 4;
         Expected : constant U64 :=
           Resident + Resident / 100 * M.Safety_Margin_Percent;
      begin
         Assert (Item.Safety_Margin = Resident / 100 * M.Safety_Margin_Percent,
                 "the safety margin is wrong:"
                 & U64'Image (Item.Safety_Margin));
         Assert (Item.Total_Resident = Expected,
                 "the plan total is not what will be resident:"
                 & U64'Image (Item.Total_Resident) & ", expected"
                 & U64'Image (Expected));
      end;
   end Plan_Sums_Its_Parts;

   --  A clock that goes backwards yields no elapsed time.
   procedure Backwards_Clock_Yields_No_Duration
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Model_Runner.Clocks.Elapsed (From => 500, To => 1_500) = 1_000,
              "an ordinary interval was measured wrongly");

      --  Subtracting an unsigned reading from a smaller one would wrap to an
      --  enormous duration, and the statistics line would report a run that
      --  took nine years.
      Assert (Model_Runner.Clocks.Elapsed (From => 1_500, To => 500) = 0,
              "a clock that went backwards produced a duration");

      Assert (Model_Runner.Clocks.Elapsed (From => 7, To => 7) = 0,
              "no elapsed time was reported as some");
   end Backwards_Clock_Yields_No_Duration;

   --  A rate over no time is not infinite.
   procedure Rate_Over_No_Time_Is_Zero
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      --  One thousand units in one millisecond is a million a second.
      Assert (Model_Runner.Clocks.Rate_Per_Second (1_000, 1_000_000)
                = 1_000_000.0,
              "a rate was computed wrongly");

      --  Dividing by nothing: the answer is not a number, and reporting one
      --  would put "inf tokens/s" in front of a reader.
      Assert (Model_Runner.Clocks.Rate_Per_Second (1_000, 0) = 0.0,
              "a rate over no elapsed time was not zero");

      Assert (Model_Runner.Clocks.Rate_Per_Second (0, 1_000_000) = 0.0,
              "no units produced a non-zero rate");
   end Rate_Over_No_Time_Is_Zero;

   ----------
   -- Name --
   ----------

   overriding function Name (T : Case_Type) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("memory accounting and clocks");
   end Name;

   ---------------------
   -- Register_Tests --
   ---------------------

   overriding procedure Register_Tests (T : in out Case_Type) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Over_Budget_Is_Refused'Access,
         "an allocation past the budget is refused before it is attempted");
      Register_Routine
        (T, Totals_Follow_Allocation'Access,
         "totals follow allocation and release, and the peak does not fall");
      Register_Routine
        (T, Mapping_Is_Counted_Apart'Access,
         "mapped bytes are not counted as allocated bytes");
      Register_Routine
        (T, Plan_Overflow_Is_Refused'Access,
         "a plan that cannot be represented is refused rather than wrapping");
      Register_Routine
        (T, Plan_Sums_Its_Parts'Access,
         "a representable plan totals its parts exactly");
      Register_Routine
        (T, Backwards_Clock_Yields_No_Duration'Access,
         "a clock that goes backwards yields no elapsed time");
      Register_Routine
        (T, Rate_Over_No_Time_Is_Zero'Access,
         "a rate over no elapsed time is zero rather than infinite");
   end Register_Tests;

end Tests.Accounting_Cases;
