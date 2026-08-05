with Model_Runner.Arithmetic;
with Model_Runner.Text;

package body Model_Runner.Memory is

   use type Interfaces.Unsigned_64;

   package A renames Model_Runner.Arithmetic;
   use type A.Checked;
   package E renames Model_Runner.Errors;

   ----------------
   -- Initialize --
   ----------------

   procedure Initialize
     (Item        : out Account;
      Model_Limit : Model_Runner.Limits.Model_Limits;
      Budget      : U64 := 0) is
   begin
      Item := (Limits => Model_Limit, Budget => Budget, others => <>);
   end Initialize;

   ----------------------
   -- Check_Allocation --
   ----------------------

   procedure Check_Allocation
     (Item   : Account;
      Kind   : Category;
      Bytes  : U64;
      Status : out Model_Runner.Errors.Error_Info) is
   begin
      Status := E.Success;

      if Item.Limits.Max_Allocation_Bytes /= 0
        and then Bytes > Item.Limits.Max_Allocation_Bytes
      then
         Status := E.Make (E.Memory_Limit_Exceeded);
         E.Add_Text (Status, "category", Category_Name (Kind), E.Param_Identifier);
         E.Add_Integer (Status, "requested", Long_Long_Integer (Bytes), E.Param_Bytes);
         E.Add_Integer
           (Status, "limit",
            Long_Long_Integer (Item.Limits.Max_Allocation_Bytes), E.Param_Bytes);
         return;
      end if;

      if Item.Budget /= 0 then
         declare
            Projected : constant A.Checked :=
              A.To_Checked (Item.Current) + A.To_Checked (Bytes);
         begin
            if not A.Is_Valid (Projected)
              or else A.Value (Projected) > Item.Budget
            then
               Status := E.Make (E.Memory_Limit_Exceeded);
               E.Add_Text
                 (Status, "category", Category_Name (Kind), E.Param_Identifier);
               E.Add_Integer
                 (Status, "requested", Long_Long_Integer (Bytes), E.Param_Bytes);
               E.Add_Integer
                 (Status, "limit", Long_Long_Integer (Item.Budget), E.Param_Bytes);
            end if;
         end;
      end if;
   end Check_Allocation;

   -----------------------
   -- Record_Allocation --
   -----------------------

   procedure Record_Allocation
     (Item  : in out Account;
      Kind  : Category;
      Bytes : U64) is
   begin
      Item.Requested := Item.Requested + Bytes;
      Item.Aligned := Item.Aligned + Bytes;
      Item.Current := Item.Current + Bytes;
      Item.By_Category (Kind) := Item.By_Category (Kind) + Bytes;
      if Item.Current > Item.Peak then
         Item.Peak := Item.Current;
      end if;
   end Record_Allocation;

   --------------------
   -- Record_Release --
   --------------------

   procedure Record_Release
     (Item  : in out Account;
      Kind  : Category;
      Bytes : U64) is
   begin
      Item.Released := Item.Released + Bytes;
      Item.Current := (if Item.Current >= Bytes then Item.Current - Bytes else 0);
      Item.By_Category (Kind) :=
        (if Item.By_Category (Kind) >= Bytes
         then Item.By_Category (Kind) - Bytes
         else 0);
   end Record_Release;

   --------------------
   -- Record_Mapping --
   --------------------

   procedure Record_Mapping (Item : in out Account; Bytes : U64) is
   begin
      Item.Mapped := Item.Mapped + Bytes;
   end Record_Mapping;

   -----------------------
   -- Record_Conversion --
   -----------------------

   procedure Record_Conversion (Item : in out Account; Bytes : U64) is
   begin
      Item.Converted := Item.Converted + Bytes;
   end Record_Conversion;

   --  Accumulate a component into a checked running total.
   procedure Accumulate (Total : in out A.Checked; Component : U64) is
   begin
      Total := Total + A.To_Checked (Component);
   end Accumulate;

   --  Build the overflow diagnostic shared by both plan finalizers.
   function Overflow_Status return E.Error_Info is
      Result : constant E.Error_Info := E.Make (E.Memory_Plan_Overflow);
   begin
      return Result;
   end Overflow_Status;

   -------------------
   -- Finalize_Plan --
   -------------------

   procedure Finalize_Plan
     (Item   : in out Plan;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Total : A.Checked := A.To_Checked (A.U64'(0));
   begin
      Accumulate (Total, Item.Copied_Bytes);
      Accumulate (Total, Item.Converted_Bytes);
      Accumulate (Total, Item.Backend_Bytes);
      Accumulate (Total, Item.Worker_Bytes);
      Accumulate (Total, Item.Conversion_Overlap);
      Accumulate (Total, Item.Alignment_Overhead);

      if not A.Is_Valid (Total) then
         Item.Valid := False;
         Status := Overflow_Status;
         return;
      end if;

      Item.Safety_Margin := A.Value (Total) / 100 * Safety_Margin_Percent;
      Accumulate (Total, Item.Safety_Margin);

      if not A.Is_Valid (Total) then
         Item.Valid := False;
         Status := Overflow_Status;
         return;
      end if;

      Item.Total_Resident := A.Value (Total);
      Item.Valid := True;
      Status := E.Success;
   end Finalize_Plan;

   ---------------------------
   -- Finalize_Session_Plan --
   ---------------------------

   procedure Finalize_Session_Plan
     (Item   : in out Session_Plan;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Total : A.Checked := A.To_Checked (A.U64'(0));
   begin
      Accumulate (Total, Item.KV_Cache_Bytes);
      Accumulate (Total, Item.Activation_Bytes);
      Accumulate (Total, Item.Batch_Bytes);
      Accumulate (Total, Item.Logits_Bytes);
      Accumulate (Total, Item.Sampling_Bytes);
      Accumulate (Total, Item.Token_History_Bytes);
      Accumulate (Total, Item.Decoder_Bytes);
      Accumulate (Total, Item.Stop_Bytes);
      Accumulate (Total, Item.Rendering_Bytes);

      if not A.Is_Valid (Total) then
         Item.Valid := False;
         Status := Overflow_Status;
         return;
      end if;

      Item.Safety_Margin := A.Value (Total) / 100 * Safety_Margin_Percent;
      Accumulate (Total, Item.Safety_Margin);

      if not A.Is_Valid (Total) then
         Item.Valid := False;
         Status := Overflow_Status;
         return;
      end if;

      Item.Total_Resident := A.Value (Total);
      Item.Valid := True;
      Status := E.Success;
   end Finalize_Session_Plan;

   -------------------
   -- Category_Name --
   -------------------

   function Category_Name (Item : Category) return String
   is (Model_Runner.Text.To_Lower (Category'Image (Item)));

end Model_Runner.Memory;
