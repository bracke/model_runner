with Ada.Calendar;
with Ada.Directories;
with Ada.Exceptions;
with Ada.Text_IO;
with Ada.Unchecked_Deallocation;
with Interfaces;

with Hostkit.Fs;

with Model_Runner.Bytes;
with Model_Runner.Numerics;
with Model_Runner.Platform;
with Model_Runner.Platform.Device;
with Model_Runner.Platform.Device.Products;
with Model_Runner.Platform.Device.Tuning;

with Fixtures;
with Host_Load;

package body Device_Tune is

   package B renames Model_Runner.Bytes;
   package N renames Model_Runner.Numerics;
   package D renames Model_Runner.Platform.Device;
   package P renames Model_Runner.Platform.Device.Products;
   package T renames Model_Runner.Platform.Device.Tuning;

   use type Ada.Calendar.Time;
   use type B.Byte_Array_Access;
   use type B.Byte_Count;
   use type N.Element_Count;
   use type N.Real;
   use type T.Launch_Choices;

   type Sample_Array is array (Positive range <>) of Long_Float;

   type Real_Array_Access is access N.Real_Array;
   procedure Free_Reals is new Ada.Unchecked_Deallocation
     (Object => N.Real_Array, Name => Real_Array_Access);

   function Median (Values : Sample_Array) return Long_Float is
      Sorted : Sample_Array := Values;
      Held   : Long_Float;
   begin
      for Index in Sorted'First + 1 .. Sorted'Last loop
         Held := Sorted (Index);
         for Before in reverse Sorted'First .. Index - 1 loop
            exit when Sorted (Before) <= Held;
            Sorted (Before + 1) := Sorted (Before);
            Sorted (Before) := Held;
         end loop;
      end loop;
      return Sorted ((Sorted'First + Sorted'Last) / 2);
   end Median;

   --  A one-per-cent winner is not evidence when the paired ratios themselves
   --  move by more than a few per cent. Alternating order removes systematic
   --  first/second bias; this bound rejects a noisy or thermally moving run
   --  before it can become a persistent profile.
   function Stable_Ratios
     (Baseline, Candidate : Sample_Array) return Boolean
   is
      Ratios : Sample_Array (Baseline'Range);
      Low    : Long_Float := Long_Float'Last;
      High   : Long_Float := 0.0;
   begin
      if Candidate'Length /= Baseline'Length then
         return False;
      end if;
      for Offset in 0 .. Baseline'Length - 1 loop
         declare
            Place : constant Positive := Baseline'First + Offset;
            Other : constant Positive := Candidate'First + Offset;
         begin
            if Baseline (Place) <= 0.0
              or else Candidate (Other) <= 0.0
            then
               return False;
            end if;
            Ratios (Place) := Candidate (Other) / Baseline (Place);
            Low := Long_Float'Min (Low, Ratios (Place));
            High := Long_Float'Max (High, Ratios (Place));
         end;
      end loop;
      declare
         Center : constant Long_Float := Median (Ratios);
      begin
         return Center > 0.0 and then High - Low <= Center * 0.03;
      end;
   end Stable_Ratios;

   function Trimmed (Value : Long_Float) return String is
      Text : constant String := Long_Float'Image (Value);
   begin
      return Text (Text'First + 1 .. Text'Last);
   end Trimmed;

   procedure Report
     (Rounds        : Positive := 7;
      Write_Profile : Boolean := False;
      Check_Profile : String := "";
      Passed        : out Boolean)
   is
      Inventory : D.Inventory;
      Context   : D.Context;
      Engine    : P.Engine;
      Found, Ready, Timed : Boolean;
      Key : T.Tuning_Key;

      --  The profile is consumed by the production executable, not by this
      --  tests executable. In a source build they are sibling crates. Where
      --  that executable cannot be identified, return no stamp: a profile
      --  keyed to the tests executable can never be consumed by production.
      function Target_Program_Stamp return String is
         Own   : constant String := Hostkit.Fs.Own_Executable;
         Bin   : constant String := Ada.Directories.Containing_Directory (Own);
         Crate : constant String := Ada.Directories.Containing_Directory (Bin);
      begin
         if Ada.Directories.Simple_Name (Crate) = "tests" then
            declare
               Root : constant String :=
                 Ada.Directories.Containing_Directory (Crate);
               Plain : constant String := Hostkit.Fs.Join
                 (Hostkit.Fs.Join (Root, "bin"), "model_runner");
               Main : constant String :=
                 (if Ada.Directories.Exists (Plain) then Plain
                  elsif Ada.Directories.Exists (Plain & ".exe")
                  then Plain & ".exe"
                  else "");
            begin
               if Main /= "" then
                  return Model_Runner.Platform.Program_Stamp (Main);
               end if;
            end;
         end if;
         return "";
      exception
         when others =>
            return "";
      end Target_Program_Stamp;

      Default : constant T.Launch_Choices := T.Default_Choices;
      Selected : T.Launch_Choices := Default;
      Selection_Margin : constant Long_Float := 0.99;
      Qualifying : constant Boolean := Check_Profile = "";

      type Candidate is record
         Name    : String (1 .. 16);
         Choices : T.Launch_Choices;
      end record;
      type Candidate_Array is array (Positive range <>) of Candidate;

      Candidates : Candidate_Array (1 .. 11) :=
        [(Name => "default         ", Choices => Default),
         (Name => "attention-wg-128", Choices => Default),
         (Name => "attention-wg-512", Choices => Default),
         (Name => "slice-at-128    ", Choices => Default),
         (Name => "slice-at-512    ", Choices => Default),
         (Name => "slice-limit-8   ", Choices => Default),
         (Name => "row-wg-128      ", Choices => Default),
         (Name => "bundle-at-128   ", Choices => Default),
         (Name => "bundle-at-512   ", Choices => Default),
         (Name => "matrix-at-17    ", Choices => Default),
         (Name => "proposed        ", Choices => Default)];

      type Candidate_Index_Array is array (Positive range <>) of Positive;
      Product_Candidates : constant Candidate_Index_Array := [1, 7, 10];

      function Wanted
        (From : Candidate_Index_Array; Only : Natural)
         return Candidate_Index_Array
      is (if Only = 0 then From else Candidate_Index_Array'[1 => Only]);

      Scores : array (Candidates'Range) of Long_Float := [others => 0.0];
      Cells  : array (Candidates'Range) of Natural := [others => 0];

      type Score_Class is (Decode, Verify, Prefill, Packed_Long);
      type Class_Scores is
        array (Candidates'Range, Score_Class) of Long_Float;
      type Class_Counts is array (Candidates'Range, Score_Class) of Natural;
      By_Class : Class_Scores := [others => [others => 0.0]];
      Class_Cells : Class_Counts := [others => [others => 0]];

      procedure Note
        (Which : Positive; Kind : Score_Class; Ratio : Long_Float)
      is
      begin
         Scores (Which) := Scores (Which) + Ratio;
         Cells (Which) := Cells (Which) + 1;
         By_Class (Which, Kind) := By_Class (Which, Kind) + Ratio;
         Class_Cells (Which, Kind) := Class_Cells (Which, Kind) + 1;
      end Note;

      function Weighted_Score (Which : Positive) return Long_Float is
         Weights : constant array (Score_Class) of Long_Float :=
           [Decode => 0.40, Verify => 0.30,
            Prefill => 0.20, Packed_Long => 0.10];
         Sum, Weight : Long_Float := 0.0;
      begin
         for Kind in Score_Class loop
            if Class_Cells (Which, Kind) > 0 then
               Sum := Sum + Weights (Kind)
                 * By_Class (Which, Kind)
                 / Long_Float (Class_Cells (Which, Kind));
               Weight := Weight + Weights (Kind);
            end if;
         end loop;
         return (if Weight = 0.0 then Long_Float'Last else Sum / Weight);
      end Weighted_Score;

      procedure Measure_Product
        (Label   : String;
         Kind    : Score_Class;
         Packing : P.Weight_Packing;
         Rows, Columns, Count : Positive;
         Weights : B.Byte_Array;
         Only    : Natural := 0);

      procedure Measure_Product
        (Label   : String;
         Kind    : Score_Class;
         Packing : P.Weight_Packing;
         Rows, Columns, Count : Positive;
         Weights : B.Byte_Array;
         Only    : Natural := 0)
      is
         Vectors : N.Real_Array
           (0 .. N.Element_Count (Columns * Count) - 1);
         Baseline, Trial : N.Real_Array
           (0 .. N.Element_Count (Rows * Count) - 1);
         Steps : P.Sequence;
         Added, Ok, Stopped, Accepted : Boolean;

         Base_Wall, Trial_Wall : Sample_Array (1 .. Rounds);
         Base_Device, Trial_Device : Sample_Array (1 .. Rounds);

         procedure Call
           (Choices : T.Launch_Choices;
            Target  : out N.Real_Array;
            Wall, Device : out Long_Float;
            Good    : out Boolean)
         is
            Began : constant Ada.Calendar.Time := Ada.Calendar.Clock;
            Line  : P.Timeline;
         begin
            P.Use_Tuning (Engine, Choices, Accepted);
            if not Accepted then
               Good := False;
               Wall := 0.0;
               Device := 0.0;
               return;
            end if;
            P.Run (Engine, Steps, Vectors, Count, Target, Ok, Stopped);
            Wall := Long_Float (Ada.Calendar.Clock - Began);
            Line := P.Last_Timeline (Engine);
            Device := Long_Float (Line.Whole) / 1.0E6;
            Good := Ok and then not Stopped and then Line.Held = 1
              and then Device > 0.0;
         end Call;

         function Same return Boolean is
         begin
            for Index in Baseline'Range loop
               if Baseline (Index) /= Baseline (Index)
                 or else Trial (Index) /= Trial (Index)
                 or else abs (Baseline (Index) - Trial (Index)) > 1.0E-4
               then
                  return False;
               end if;
            end loop;
            return True;
         end Same;
      begin
         for Index in Vectors'Range loop
            Vectors (Index) :=
              N.Real (Integer (Natural (Index) mod 17) - 8) / 32.0;
         end loop;
         P.Open_Sequence (Steps);
         P.Add_Product
           (Steps, Weights'Address, B.Byte_Count (Weights'Length), 0,
            Packing, Rows, Columns, Added, Key => Weights (Weights'First)'Address);
         if not Added then
            Passed := False;
            return;
         end if;

         for Which of Wanted (Product_Candidates, Only) loop
            declare
               Wall, Device : Long_Float;
               Good : Boolean;
            begin
               --  Warm both pipelines and the resident matrix.
               Call (Default, Baseline, Wall, Device, Good);
               if Good then
                  Call
                    (Candidates (Which).Choices, Trial, Wall, Device, Good);
               end if;
               if not Good or else not Same then
                  Passed := False;
                  Ada.Text_IO.Put_Line
                    ("reject " & Candidates (Which).Name & " " & Label
                     & ": wrong or unavailable");
                  return;
               end if;

               for Round in 1 .. Rounds loop
                  if Round mod 2 = 1 then
                     Call (Default, Baseline, Base_Wall (Round),
                           Base_Device (Round), Good);
                     if Good then
                        Call (Candidates (Which).Choices, Trial,
                              Trial_Wall (Round), Trial_Device (Round), Good);
                     end if;
                  else
                     Call (Candidates (Which).Choices, Trial,
                           Trial_Wall (Round), Trial_Device (Round), Good);
                     if Good then
                        Call (Default, Baseline, Base_Wall (Round),
                              Base_Device (Round), Good);
                     end if;
                  end if;
                  if not Good or else not Same then
                     Passed := False;
                     Ada.Text_IO.Put_Line
                       ("reject " & Candidates (Which).Name & " " & Label
                        & ": a measured answer changed");
                     return;
                  end if;
               end loop;

               if Qualifying
                 and then not Stable_Ratios (Base_Device, Trial_Device)
               then
                  Passed := False;
                  Ada.Text_IO.Put_Line
                    ("reject " & Candidates (Which).Name & " " & Label
                     & ": device timings were not stable");
                  return;
               end if;

               declare
                  BW : constant Long_Float := Median (Base_Wall);
                  TW : constant Long_Float := Median (Trial_Wall);
                  BD : constant Long_Float := Median (Base_Device);
                  TD : constant Long_Float := Median (Trial_Device);
                  Ratio : constant Long_Float := TD / BD;
               begin
                  Ada.Text_IO.Put_Line
                    (Candidates (Which).Name & " " & Label
                     & " wall=" & Trimmed (TW * 1.0E6)
                     & "us base=" & Trimmed (BW * 1.0E6)
                     & "us device=" & Trimmed (TD * 1.0E6)
                     & "us base=" & Trimmed (BD * 1.0E6)
                     & "us ratio=" & Trimmed (Ratio));
                  Note (Which, Kind, Ratio);
               end;
            end;
         end loop;
      end Measure_Product;

      procedure Measure_Attention
        (Label : String;
         Kind : Score_Class;
         Depth, Positions : Positive;
         Only : Natural := 0)
      is
         Heads     : constant Positive := 8;
         Head_Size : constant Positive := 64;
         Groups    : constant Positive := 2;
         Span      : constant Positive := Heads * Head_Size;
         Narrow    : constant Positive := Groups * Head_Size;

         Cache, Query, Baseline, Trial : Real_Array_Access := null;
         Identity : B.Byte_Array_Access := null;
         Steps    : P.Sequence;
         Added, Ok, Stopped, Accepted : Boolean;

         Base_Wall, Trial_Wall : Sample_Array (1 .. Rounds);
         Base_Device, Trial_Device : Sample_Array (1 .. Rounds);

         procedure Release is
         begin
            B.Free (Identity);
            Free_Reals (Trial);
            Free_Reals (Baseline);
            Free_Reals (Query);
            Free_Reals (Cache);
         end Release;

         procedure Call
           (Choices : T.Launch_Choices;
            Target  : out N.Real_Array;
            Wall, Device : out Long_Float;
            Good    : out Boolean)
         is
            Began : constant Ada.Calendar.Time := Ada.Calendar.Clock;
            Line  : P.Timeline;
         begin
            P.Use_Tuning (Engine, Choices, Accepted);
            if not Accepted then
               Good := False;
               Wall := 0.0;
               Device := 0.0;
               return;
            end if;
            P.Run (Engine, Steps, Query.all, Positions,
                   Target, Ok, Stopped);
            Wall := Long_Float (Ada.Calendar.Clock - Began);
            Line := P.Last_Timeline (Engine);
            Device := Long_Float (Line.Whole) / 1.0E6;
            Good := Ok and then not Stopped and then Line.Held = 2
              and then Device > 0.0;
         end Call;

         function Same return Boolean is
         begin
            for Index in Baseline.all'Range loop
               if Baseline (Index) /= Baseline (Index)
                 or else Trial (Index) /= Trial (Index)
                 or else abs (Baseline (Index) - Trial (Index)) > 1.0E-4
               then
                  return False;
               end if;
            end loop;
            return True;
         end Same;
      begin
         if Positions > Depth then
            Passed := False;
            return;
         end if;
         Cache := new N.Real_Array
           (0 .. N.Element_Count (2 * Depth * Narrow) - 1);
         Query := new N.Real_Array
           (0 .. N.Element_Count (Positions * Span) - 1);
         Baseline := new N.Real_Array
           (0 .. N.Element_Count (2 * Positions * Span) - 1);
         Trial := new N.Real_Array
           (0 .. N.Element_Count (2 * Positions * Span) - 1);
         for Index in Cache.all'Range loop
            Cache (Index) :=
              N.Real (Integer (Natural (Index) mod 19) - 9) / 64.0;
         end loop;
         for Index in Query.all'Range loop
            Query (Index) :=
              N.Real (Integer (Natural (Index) mod 13) - 6) / 32.0;
         end loop;
         B.Allocate (B.Byte_Count (Span * Span * 4), Identity, False);
         if Identity = null then
            Passed := False;
            Release;
            return;
         end if;
         Identity.all := [others => 0];
         for Row in 0 .. Span - 1 loop
            declare
               Where : constant B.Byte_Count :=
                 B.Byte_Count ((Row * Span + Row) * 4) + B.Byte_Count'(1);
            begin
               Identity (Where .. Where + B.Byte_Count'(3)) :=
                 B.Put_F32 (1.0);
            end;
         end loop;

         P.Reserve (Engine, Cache.all'Length, Cache.all'Length, Ok);
         if Ok then
            P.Put_Cache (Engine, 0, Cache.all, Ok);
         end if;
         P.Open_Sequence (Steps);
         if Ok then
            P.Add_Product
              (Steps, Identity.all'Address, B.Byte_Count (Identity.all'Length),
               0, P.Values_F32, Span, Span, Added,
               Key => Identity (Identity'First)'Address);
            Ok := Added;
         end if;
         if Ok then
            P.Add_Attention
              (Steps, Heads => Heads, Head_Size => Head_Size,
               Value_Size => Head_Size, Group_Size => Heads / Groups,
               First => 0, Last => Depth - Positions,
               K_Base => 0, V_Base => N.Element_Count (Depth * Narrow),
               KV_Width => Narrow, V_Width => Narrow,
               Scale => 0.125, Cap => 0.0, Added => Added,
               Chained => True);
            Ok := Added;
         end if;
         if not Ok then
            Ada.Text_IO.Put_Line ("reject attention " & Label & ": setup");
            Passed := False;
            Release;
            return;
         end if;

         for Which of Wanted ([1, 2, 3, 4, 5, 6], Only) loop
            declare
               Wall, Device : Long_Float;
               Good : Boolean;
            begin
               Call (Default, Baseline.all, Wall, Device, Good);
               if Good then
                  Call (Candidates (Which).Choices, Trial.all,
                        Wall, Device, Good);
               end if;
               if not Good or else not Same then
                  Ada.Text_IO.Put_Line
                    ("reject " & Candidates (Which).Name & " " & Label
                     & ": wrong or unavailable");
                  Passed := False;
                  Release;
                  return;
               end if;
               for Round in 1 .. Rounds loop
                  if Round mod 2 = 1 then
                     Call (Default, Baseline.all, Base_Wall (Round),
                           Base_Device (Round), Good);
                     if Good then
                        Call (Candidates (Which).Choices, Trial.all,
                              Trial_Wall (Round), Trial_Device (Round), Good);
                     end if;
                  else
                     Call (Candidates (Which).Choices, Trial.all,
                           Trial_Wall (Round), Trial_Device (Round), Good);
                     if Good then
                        Call (Default, Baseline.all, Base_Wall (Round),
                              Base_Device (Round), Good);
                     end if;
                  end if;
                  if not Good or else not Same then
                     Ada.Text_IO.Put_Line
                       ("reject " & Candidates (Which).Name & " " & Label
                        & ": a measured answer changed");
                     Passed := False;
                     Release;
                     return;
                  end if;
               end loop;
               if Qualifying
                 and then not Stable_Ratios (Base_Device, Trial_Device)
               then
                  Ada.Text_IO.Put_Line
                    ("reject " & Candidates (Which).Name & " " & Label
                     & ": device timings were not stable");
                  Passed := False;
                  Release;
                  return;
               end if;
               declare
                  BW : constant Long_Float := Median (Base_Wall);
                  TW : constant Long_Float := Median (Trial_Wall);
                  BD : constant Long_Float := Median (Base_Device);
                  TD : constant Long_Float := Median (Trial_Device);
                  Ratio : constant Long_Float := TD / BD;
               begin
                  Ada.Text_IO.Put_Line
                    (Candidates (Which).Name & " " & Label
                     & " wall=" & Trimmed (TW * 1.0E6)
                     & "us base=" & Trimmed (BW * 1.0E6)
                     & "us device=" & Trimmed (TD * 1.0E6)
                     & "us base=" & Trimmed (BD * 1.0E6)
                     & "us ratio=" & Trimmed (Ratio));
                  Note (Which, Kind, Ratio);
               end;
            end;
         end loop;
         Release;
      exception
         when others =>
            Release;
            raise;
      end Measure_Attention;

      procedure Measure_Packed
        (Label       : String;
         Kind        : Score_Class;
         Depth       : Positive;
         Positions   : Positive;
         Bits        : Positive;
         Transformed : Boolean := False;
         Only        : Natural := 0)
      is
         Heads     : constant Positive := 8;
         Head_Size : constant Positive := 64;
         Groups    : constant Positive := 2;
         Span      : constant Positive := Heads * Head_Size;
         Narrow    : constant Positive := Groups * Head_Size;
         Row_Bytes : constant Positive :=
           (if Bits = 4 then Narrow / 2 else Narrow);
         Blocks    : constant Positive :=
           (if Bits = 4 then Narrow / 32 else 1);

         Base        : constant Natural := 16;
         Key_Words   : constant Natural := (Depth * Row_Bytes + 3) / 4;
         Value_At    : constant Natural := Base + Key_Words;
         Value_Words : constant Natural := (Depth * Row_Bytes + 3) / 4;
         K_Scale_At  : constant Natural := Value_At + Value_Words;
         V_Scale_At  : constant Natural := K_Scale_At + Depth * Blocks;
         Whole       : constant Natural := V_Scale_At + Depth * Blocks;

         Query, K_Scales, V_Scales, Baseline, Trial : Real_Array_Access := null;
         Key_Bytes, Value_Bytes, Identity : B.Byte_Array_Access := null;
         Steps : P.Sequence;
         Added, Ok, Stopped, Accepted : Boolean;

         Packed_Candidates : constant Candidate_Index_Array :=
           [1, 2, 3, 4, 5, 6, 8, 9];
         Base_Wall, Trial_Wall : Sample_Array (1 .. Rounds);
         Base_Device, Trial_Device : Sample_Array (1 .. Rounds);

         procedure Release is
         begin
            B.Free (Key_Bytes);
            B.Free (Value_Bytes);
            B.Free (Identity);
            Free_Reals (Trial);
            Free_Reals (Baseline);
            Free_Reals (V_Scales);
            Free_Reals (K_Scales);
            Free_Reals (Query);
         end Release;

         procedure Call
           (Choices : T.Launch_Choices;
            Target  : out N.Real_Array;
            Wall, Device : out Long_Float;
            Good    : out Boolean)
         is
            Began : constant Ada.Calendar.Time := Ada.Calendar.Clock;
            Line  : P.Timeline;
         begin
            P.Use_Tuning (Engine, Choices, Accepted);
            if not Accepted then
               Good := False;
               Wall := 0.0;
               Device := 0.0;
               return;
            end if;
            P.Run (Engine, Steps, Query.all, Positions,
                   Target, Ok, Stopped);
            Wall := Long_Float (Ada.Calendar.Clock - Began);
            Line := P.Last_Timeline (Engine);
            Device := Long_Float (Line.Whole) / 1.0E6;
            Good := Ok and then not Stopped and then Line.Held = 2
              and then Device > 0.0;
         end Call;

         function Same return Boolean is
         begin
            for Index in Baseline.all'Range loop
               if Baseline (Index) /= Baseline (Index)
                 or else Trial (Index) /= Trial (Index)
                 or else abs (Baseline (Index) - Trial (Index)) > 1.0E-4
               then
                  return False;
               end if;
            end loop;
            return True;
         end Same;
      begin
         if Positions > Depth then
            Passed := False;
            return;
         end if;
         Query := new N.Real_Array
           (0 .. N.Element_Count (Positions * Span) - 1);
         K_Scales := new N.Real_Array
           (0 .. N.Element_Count (Depth * Blocks) - 1);
         V_Scales := new N.Real_Array
           (0 .. N.Element_Count (Depth * Blocks) - 1);
         Baseline := new N.Real_Array
           (0 .. N.Element_Count (2 * Positions * Span) - 1);
         Trial := new N.Real_Array
           (0 .. N.Element_Count (2 * Positions * Span) - 1);
         B.Allocate (B.Byte_Count (Depth * Row_Bytes), Key_Bytes, False);
         B.Allocate (B.Byte_Count (Depth * Row_Bytes), Value_Bytes, False);
         B.Allocate (B.Byte_Count (Span * Span * 4), Identity, False);
         if Key_Bytes = null or else Value_Bytes = null
           or else Identity = null
         then
            Passed := False;
            Release;
            return;
         end if;
         for Index in Key_Bytes.all'Range loop
            if Bits = 4 then
               Key_Bytes (Index) :=
                 B.Byte ((Natural (Index) mod 16)
                         + 16 * ((Natural (Index) / 3) mod 16));
               Value_Bytes (Index) :=
                 B.Byte (((Natural (Index) + 5) mod 16)
                         + 16 * ((Natural (Index) / 5) mod 16));
            else
               Key_Bytes (Index) :=
                 B.Byte (121 + Natural (Index) mod 15);
               Value_Bytes (Index) :=
                 B.Byte (123 + Natural (Index) mod 11);
            end if;
         end loop;
         for Index in K_Scales.all'Range loop
            K_Scales (Index) :=
              0.01 + N.Real (Natural (Index) mod 7) / 1_000.0;
            V_Scales (Index) :=
              0.01 + N.Real (Natural (Index) mod 5) / 1_000.0;
         end loop;
         for Index in Query.all'Range loop
            Query (Index) :=
              N.Real (Integer (Natural (Index) mod 13) - 6) / 32.0;
         end loop;
         Identity.all := [others => 0];
         for Row in 0 .. Span - 1 loop
            declare
               Where : constant B.Byte_Count :=
                 B.Byte_Count ((Row * Span + Row) * 4) + B.Byte_Count'(1);
            begin
               Identity (Where .. Where + B.Byte_Count'(3)) :=
                 B.Put_F32 (1.0);
            end;
         end loop;

         P.Reserve (Engine, N.Element_Count (Whole), 0, Ok);
         if Ok then
            P.Put_Bytes
              (Engine, Interfaces.Unsigned_64 (Base * 4),
               Key_Bytes.all, Ok);
         end if;
         if Ok then
            P.Put_Bytes
              (Engine, Interfaces.Unsigned_64 (Value_At * 4),
               Value_Bytes.all, Ok);
         end if;
         if Ok then
            P.Put_Cache (Engine, N.Element_Count (K_Scale_At),
                         K_Scales.all, Ok);
         end if;
         if Ok then
            P.Put_Cache (Engine, N.Element_Count (V_Scale_At),
                         V_Scales.all, Ok);
         end if;

         P.Open_Sequence (Steps);
         if Ok then
            P.Add_Product
              (Steps, Identity.all'Address, B.Byte_Count (Identity.all'Length),
               0, P.Values_F32, Span, Span, Added,
               Key => Identity (Identity'First)'Address);
            Ok := Added;
         end if;
         if Ok then
            P.Add_Attention
              (Steps, Heads => Heads, Head_Size => Head_Size,
               Value_Size => Head_Size, Group_Size => Heads / Groups,
               First => 0, Last => Depth - Positions,
               K_Base => 0, V_Base => 0,
               KV_Width => Narrow, V_Width => Narrow,
               Scale => 0.125, Cap => 0.0, Added => Added,
               Chained => True,
               Packed =>
                 (K_Codec =>
                    (if Transformed
                     then P.Transformed_Four_Bit_Cache
                     else P.Scaled_Integer_Cache),
                  V_Codec => P.Scaled_Integer_Cache,
                  K_Bits => Bits, V_Bits => Bits,
                  K_Bytes => Interfaces.Unsigned_64 (Base * 4),
                  V_Bytes => Interfaces.Unsigned_64 (Value_At * 4),
                  KS_At => K_Scale_At, VS_At => V_Scale_At,
                  K_Blocks => Blocks, V_Blocks => Blocks));
            Ok := Added;
         end if;
         if not Ok then
            Ada.Text_IO.Put_Line ("reject packed " & Label & ": setup");
            Passed := False;
            Release;
            return;
         end if;

         for Which of Wanted (Packed_Candidates, Only) loop
            declare
               Wall, Device : Long_Float;
               Good : Boolean;
            begin
               Call (Default, Baseline.all, Wall, Device, Good);
               if Good then
                  Call (Candidates (Which).Choices, Trial.all,
                        Wall, Device, Good);
               end if;
               if not Good or else not Same then
                  Ada.Text_IO.Put_Line
                    ("reject " & Candidates (Which).Name & " " & Label
                     & ": wrong or unavailable");
                  Passed := False;
                  Release;
                  return;
               end if;
               for Round in 1 .. Rounds loop
                  if Round mod 2 = 1 then
                     Call (Default, Baseline.all, Base_Wall (Round),
                           Base_Device (Round), Good);
                     if Good then
                        Call (Candidates (Which).Choices, Trial.all,
                              Trial_Wall (Round), Trial_Device (Round), Good);
                     end if;
                  else
                     Call (Candidates (Which).Choices, Trial.all,
                           Trial_Wall (Round), Trial_Device (Round), Good);
                     if Good then
                        Call (Default, Baseline.all, Base_Wall (Round),
                              Base_Device (Round), Good);
                     end if;
                  end if;
                  if not Good or else not Same then
                     Ada.Text_IO.Put_Line
                       ("reject " & Candidates (Which).Name & " " & Label
                        & ": a measured answer changed");
                     Passed := False;
                     Release;
                     return;
                  end if;
               end loop;
               if Qualifying
                 and then not Stable_Ratios (Base_Device, Trial_Device)
               then
                  Ada.Text_IO.Put_Line
                    ("reject " & Candidates (Which).Name & " " & Label
                     & ": device timings were not stable");
                  Passed := False;
                  Release;
                  return;
               end if;
               declare
                  BW : constant Long_Float := Median (Base_Wall);
                  TW : constant Long_Float := Median (Trial_Wall);
                  BD : constant Long_Float := Median (Base_Device);
                  TD : constant Long_Float := Median (Trial_Device);
                  Ratio : constant Long_Float := TD / BD;
               begin
                  Ada.Text_IO.Put_Line
                    (Candidates (Which).Name & " " & Label
                     & " wall=" & Trimmed (TW * 1.0E6)
                     & "us base=" & Trimmed (BW * 1.0E6)
                     & "us device=" & Trimmed (TD * 1.0E6)
                     & "us base=" & Trimmed (BD * 1.0E6)
                     & "us ratio=" & Trimmed (Ratio));
                  Note (Which, Kind, Ratio);
               end;
            end;
         end loop;
         Release;
      exception
         when others =>
            Release;
            raise;
      end Measure_Packed;

      procedure Product_Set
        (Label : String;
         Kind : Score_Class;
         Rows, Columns, Count : Positive;
         Only : Natural := 0)
      is
         Values : N.Real_Array
           (0 .. N.Element_Count (Rows * Columns) - 1);
      begin
         for Index in Values'Range loop
            Values (Index) :=
              N.Real (Integer (Natural (Index) mod 23) - 11) / 64.0;
         end loop;
         declare
            F32 : constant B.Byte_Array := Fixtures.Encode_F32 (Values);
            Q8  : constant B.Byte_Array := Fixtures.Encode_Q8_0 (Values);
            Q4  : constant B.Byte_Array := Fixtures.Encode_Q4_0 (Values);
         begin
            Measure_Product (Label & "/f32", Kind, P.Values_F32,
                             Rows, Columns, Count, F32, Only);
            Measure_Product (Label & "/q8", Kind, P.Packed_Q8_0,
                             Rows, Columns, Count, Q8, Only);
            Measure_Product (Label & "/q4", Kind, P.Packed_Q4_0,
                             Rows, Columns, Count, Q4, Only);
         end;
      end Product_Set;

      procedure Campaign (Only : Natural := 0) is
      begin
         Product_Set ("narrow/one", Decode, 256, 512, 1, Only);
         Product_Set ("verify/four", Verify, 256, 512, 4, Only);
         Product_Set ("verify/eight", Verify, 256, 512, 8, Only);
         Product_Set ("prefill/sixteen", Prefill, 256, 512, 16, Only);
         Product_Set
           ("prefill/thirty-two", Prefill, 256, 512, 32, Only);
         Product_Set ("feed-forward/one", Decode, 512, 512, 1, Only);
         Measure_Attention
           ("attention/short/token", Decode, 128, 1, Only);
         Measure_Attention
           ("attention/1419/token", Decode, 1_419, 1, Only);
         Measure_Attention
           ("attention/long/token", Decode, 16_384, 1, Only);
         Measure_Attention
           ("attention/verify/two", Verify, 1_419, 2, Only);
         Measure_Attention
           ("attention/verify/four", Verify, 1_419, 4, Only);
         Measure_Attention
           ("attention/verify/eight", Verify, 1_419, 8, Only);
         Measure_Attention
           ("attention/prefill/sixteen", Prefill, 1_419, 16, Only);
         Measure_Attention
           ("attention/prefill/thirty-two", Prefill, 1_419, 32, Only);
         if P.Attends_Packed (Engine) then
            Measure_Packed
              ("packed/q8/1419/token", Decode, 1_419, 1, 8,
               Only => Only);
            Measure_Packed
              ("packed/q4/1419/token", Decode, 1_419, 1, 4,
               Only => Only);
            Measure_Packed
              ("packed/q4t/1419/token", Decode, 1_419, 1, 4,
               Transformed => True, Only => Only);
            Measure_Packed
              ("packed/q4t/long/token", Packed_Long, 16_384, 1, 4,
               Transformed => True, Only => Only);
            Measure_Packed
              ("packed/q4t/verify/eight", Verify, 1_419, 8, 4,
               Transformed => True, Only => Only);
            Measure_Packed
              ("packed/q4t/prefill/sixteen", Prefill, 1_419, 16, 4,
               Transformed => True, Only => Only);
         elsif Only = 0 then
            Ada.Text_IO.Put_Line
              ("device-tune: packed attention is unavailable; skipped");
         end if;
      end Campaign;
   begin
      Passed := True;
      Candidates (2).Choices.Attention_Workgroups := 128;
      Candidates (3).Choices.Attention_Workgroups := 512;
      Candidates (4).Choices.Attention_Slice_Least := 128;
      Candidates (5).Choices.Attention_Slice_Least := 512;
      Candidates (6).Choices.Attention_Slice_Limit := 8;
      Candidates (7).Choices.Row_Product_Workgroup := 128;
      Candidates (8).Choices.Packed_Bundle_Least := 128;
      Candidates (9).Choices.Packed_Bundle_Least := 512;
      Candidates (10).Choices.Matrix_Row_Crossover := 17;

      --  A replay checks correctness and may run on a busy host. A campaign
      --  that proposes or writes performance policy is evidence, and goes
      --  through the same quiet-machine gate as the repository's other
      --  published timings.
      if Qualifying and then not Host_Load.Settle (0, False) then
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error,
            "device-tune: machine is too busy to qualify a profile");
         Passed := False;
         return;
      end if;

      D.Open (Inventory, Found);
      if not Found or else D.Count (Inventory) = 0 then
         Ada.Text_IO.Put_Line ("device-tune: no device");
         Passed := False;
         return;
      end if;
      Ada.Text_IO.Put_Line
        ("device-tune: device 1: " & D.Name (Inventory, 1)
         & (if D.Is_Software (Inventory, 1)
            then " (software)" else " (hardware)"));
      if D.Is_Software (Inventory, 1) then
         Ada.Text_IO.Put_Line
           ("device-tune: device 1 is a software rasterizer; "
            & "no hardware profile was written");
         Passed := False;
         D.Close (Inventory);
         return;
      end if;
      D.Open (Context, Inventory, 1, Ready);
      if Ready then
         P.Open (Engine, Context, Ready);
      end if;
      if not Ready then
         Ada.Text_IO.Put_Line ("device-tune: device would not open");
         Passed := False;
         --  Either the context failed to open, or Products.Open failed after
         --  the context had opened.  Both Close operations are idempotent,
         --  so release both partial resources before returning.
         P.Close (Engine);
         D.Close (Context);
         D.Close (Inventory);
         return;
      end if;
      Key := T.Create_Key
        (D.Identity (Context), T.Shader_Stamp, Target_Program_Stamp);
      P.Time_Steps (Engine, True, Timed);
      if not Timed then
         Ada.Text_IO.Put_Line ("device-tune: device timestamps unavailable");
         Passed := False;
      elsif Check_Profile /= "" then
         declare
            Loaded : T.Launch_Choices;
            Found_Profile : Boolean;
         begin
            if not T.Is_Valid (Key) then
               Ada.Text_IO.Put_Line
                 ("device-tune: this executable has no valid tuning key");
               Passed := False;
            else
               T.Load (Check_Profile, Key, Loaded, Found_Profile);
               if not Found_Profile then
                  Ada.Text_IO.Put_Line
                    ("device-tune: profile is absent, invalid, or stale: "
                     & Check_Profile);
                  Passed := False;
               else
                  Candidates (11).Choices := Loaded;
                  Campaign (11);
                  if Passed then
                     Ada.Text_IO.Put_Line
                       ("device-tune: profile replay passed every shape");
                  end if;
               end if;
            end if;
         end;
      else
         Campaign;
      end if;

      --  A quiet start does not prove that another workload stayed away.
      --  Refuse to select or persist a profile if the host is busy when the
      --  campaign ends; the paired-ratio stability checks above cover a
      --  disturbance that came and went before this final sample.
      if Qualifying and then Passed and then not Host_Load.Quiet_Enough then
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error,
            "device-tune: machine became busy during the campaign; "
            & "no profile qualified");
         Passed := False;
      end if;

      if Passed and then Check_Profile = "" then
         declare
            function Faster (Left, Right : Positive) return Positive is
              (if Weighted_Score (Left) <= Weighted_Score (Right)
               then Left else Right);
            Winner : Positive;
         begin
            Winner := Faster (2, 3);
            if Weighted_Score (Winner) < Selection_Margin then
               Selected.Attention_Workgroups :=
                 Candidates (Winner).Choices.Attention_Workgroups;
            end if;

            Winner := Faster (4, 5);
            if Weighted_Score (Winner) < Selection_Margin then
               Selected.Attention_Slice_Least :=
                 Candidates (Winner).Choices.Attention_Slice_Least;
            end if;

            if Weighted_Score (6) < Selection_Margin then
               Selected.Attention_Slice_Limit :=
                 Candidates (6).Choices.Attention_Slice_Limit;
            end if;
            if Weighted_Score (7) < Selection_Margin then
               Selected.Row_Product_Workgroup :=
                 Candidates (7).Choices.Row_Product_Workgroup;
            end if;

            Winner := Faster (8, 9);
            if Weighted_Score (Winner) < Selection_Margin then
               Selected.Packed_Bundle_Least :=
                 Candidates (Winner).Choices.Packed_Bundle_Least;
            end if;

            --  Packed_Cuts_A_Round remains at its safe default: the
            --  dispatch does not yet distinguish a round for this choice,
            --  so the campaign deliberately does not claim to measure it.
            if Weighted_Score (10) < Selection_Margin then
               Selected.Matrix_Row_Crossover :=
                 Candidates (10).Choices.Matrix_Row_Crossover;
            end if;
         end;

         Candidates (11).Choices := Selected;
         Ada.Text_IO.Put_Line
           ("combined replay against defaults (all shapes):");
         Campaign (11);

         if Passed and then Selected /= Default
           and then Weighted_Score (12) >= Selection_Margin
         then
            Ada.Text_IO.Put_Line
              ("device-tune: combined policy did not retain the 1% win; "
               & "no profile proposed");
            Selected := Default;
         end if;

         if Passed then
            Ada.Text_IO.Put_Line
              ("weighted scores (lower is faster; default ratio is 1):");
            for Which in Candidates'Range loop
               if Cells (Which) = 0 then
                  Ada.Text_IO.Put_Line
                    ("  " & Candidates (Which).Name & " not measured yet");
               else
                  Ada.Text_IO.Put_Line
                    ("  " & Candidates (Which).Name & " "
                     & Trimmed (Weighted_Score (Which)));
               end if;
            end loop;
            Ada.Text_IO.Put_Line
              ("proposed (requires 1% median win and combined replay):");
            Ada.Text_IO.Put_Line
              ("  attention-workgroups"
               & T.Workgroup_Count'Image (Selected.Attention_Workgroups)
               & ", slice-least"
               & T.Position_Count'Image (Selected.Attention_Slice_Least)
               & ", slice-limit"
               & T.Slice_Count'Image (Selected.Attention_Slice_Limit));
            Ada.Text_IO.Put_Line
              ("  row-workgroup"
               & T.Workgroup_Count'Image (Selected.Row_Product_Workgroup)
               & ", packed-bundle-least"
               & T.Position_Count'Image (Selected.Packed_Bundle_Least)
               & ", matrix-crossover"
               & T.Batch_Count'Image (Selected.Matrix_Row_Crossover));

            if Write_Profile then
               if Selected = Default then
                  Ada.Text_IO.Put_Line
                    ("device-tune: defaults won; no profile written");
               elsif not T.Is_Valid (Key) then
                  Ada.Text_IO.Put_Line
                    ("device-tune: this executable has no valid tuning key");
                  Passed := False;
               else
                  declare
                     Path : constant String := T.Profile_Path (Key);
                     Written : Boolean;
                  begin
                     if Path = "" then
                        Ada.Text_IO.Put_Line
                          ("device-tune: no tuning cache path is available");
                        Passed := False;
                     else
                        T.Store (Path, Key, Selected, Written);
                        Passed := Written;
                        Ada.Text_IO.Put_Line
                          ((if Written
                            then "device-tune: wrote " & Path
                            else "device-tune: profile write failed: "
                              & Path));
                     end if;
                  end;
               end if;
            end if;
         end if;
      end if;
      P.Time_Steps (Engine, False, Timed);
      P.Close (Engine);
      D.Close (Context);
      D.Close (Inventory);
   exception
      when Fault : others =>
         Passed := False;
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error,
            "device-tune: " & Ada.Exceptions.Exception_Information (Fault));
         P.Close (Engine);
         D.Close (Context);
         D.Close (Inventory);
   end Report;

end Device_Tune;
