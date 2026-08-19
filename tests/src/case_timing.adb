with Ada.Calendar;
with Ada.Text_IO;

with AUnit;
with AUnit.Options;
with AUnit.Reporter.Text;
with AUnit.Run;
with AUnit.Test_Cases;
with AUnit.Test_Filters;
with AUnit.Test_Suites;

with Tests.Accounting_Cases;
with Tests.Backend_Cases;
with Tests.Catalog_Cases;
with Tests.CLI_Cases;
with Tests.GGUF_Cases;
with Tests.Grammar_Cases;
with Tests.Inference_Cases;
with Tests.Sampling_Cases;
with Tests.Template_Cases;

package body Case_Timing is

   --  One case, and what it cost.
   type Timing is record
      Name  : String (1 .. 24) := [others => ' '];
      Last  : Natural := 0;
      Spent : Duration := 0.0;
   end record;

   Held : array (1 .. 9) of Timing;

   Quiet : constant AUnit.Options.AUnit_Options :=
     (Global_Timer     => False,
      Test_Case_Timer  => False,
      Report_Successes => False,
      Filter           => null);

   --  Somewhere for one case to be added to, made afresh for each so that a
   --  case is never run twice over.
   GGUF_Case       : aliased Tests.GGUF_Cases.Case_Type;
   Inference_Case  : aliased Tests.Inference_Cases.Case_Type;
   Sampling_Case   : aliased Tests.Sampling_Cases.Case_Type;
   CLI_Case        : aliased Tests.CLI_Cases.Case_Type;
   Catalog_Case    : aliased Tests.Catalog_Cases.Case_Type;
   Backend_Case    : aliased Tests.Backend_Cases.Case_Type;
   Accounting_Case : aliased Tests.Accounting_Cases.Case_Type;
   Template_Case   : aliased Tests.Template_Cases.Case_Type;
   Grammar_Case    : aliased Tests.Grammar_Cases.Case_Type;

   --  One suite for each case rather than one reused: a suite is a limited
   --  type and cannot be emptied, and a case added twice would run twice.
   Room : array (1 .. 9) of aliased AUnit.Test_Suites.Test_Suite;

   Which : Natural := 1;

   function Only return AUnit.Test_Suites.Access_Test_Suite
   is (Room (Which)'Access);

   function Run_One is new AUnit.Run.Test_Runner_With_Status (Only);

   Reporter : AUnit.Reporter.Text.Text_Reporter;

   ------------
   -- Report --
   ------------

   procedure Report is
      use type Ada.Calendar.Time;

      Count : Natural := 0;

      --  Run one case on its own and keep what it took.
      procedure Take
        (Named : String; What : access AUnit.Test_Cases.Test_Case'Class);

      procedure Take
        (Named : String; What : access AUnit.Test_Cases.Test_Case'Class)
      is
         Started : Ada.Calendar.Time;
         Ignored : AUnit.Status;
      begin
         Count := Count + 1;
         Which := Count;
         AUnit.Test_Suites.Add_Test (Room (Which)'Access, What);

         Started := Ada.Calendar.Clock;
         Ignored := Run_One (Reporter, Quiet);

         Held (Count).Spent := Ada.Calendar.Clock - Started;
         declare
            Kept : constant String :=
              Named (Named'First
                     .. Natural'Min (Named'Last,
                                     Named'First + Held (Count).Name'Length
                                     - 1));
         begin
            Held (Count).Name (1 .. Kept'Length) := Kept;
            Held (Count).Last := Kept'Length;
         end;
      end Take;

      Whole : Duration := 0.0;
   begin
      Take ("gguf", GGUF_Case'Access);
      Take ("inference", Inference_Case'Access);
      Take ("sampling", Sampling_Case'Access);
      Take ("cli", CLI_Case'Access);
      Take ("catalog", Catalog_Case'Access);
      Take ("backend", Backend_Case'Access);
      Take ("accounting", Accounting_Case'Access);
      Take ("template", Template_Case'Access);
      Take ("grammar", Grammar_Case'Access);

      for Index in 1 .. Count loop
         Whole := Whole + Held (Index).Spent;
      end loop;

      --  Longest first.
      for Outer in 1 .. Count loop
         declare
            Best : Positive := Outer;
         begin
            for Inner in Outer + 1 .. Count loop
               if Held (Inner).Spent > Held (Best).Spent then
                  Best := Inner;
               end if;
            end loop;

            if Best /= Outer then
               declare
                  Swap : constant Timing := Held (Outer);
               begin
                  Held (Outer) := Held (Best);
                  Held (Best) := Swap;
               end;
            end if;
         end;
      end loop;

      Ada.Text_IO.New_Line;
      Ada.Text_IO.Put_Line
        ("case timings, of a whole" & Duration'Image (Whole) & " s:");
      for Index in 1 .. Count loop
         Ada.Text_IO.Put_Line
           ("  " & Duration'Image (Held (Index).Spent) & " s  "
            & Held (Index).Name (1 .. Held (Index).Last));
      end loop;
   end Report;

   ---------------------
   -- Report_Routines --
   ---------------------

   procedure Report_Routines (Named : String) is
      use type Ada.Calendar.Time;

      Filter : aliased AUnit.Test_Filters.Name_Filter;

      Picked : constant AUnit.Options.AUnit_Options :=
        (Global_Timer     => False,
         Test_Case_Timer  => False,
         Report_Successes => False,
         Filter           => Filter'Unchecked_Access);

      Ignored : AUnit.Status;
      Started : Ada.Calendar.Time;
   begin
      --  One routine a process. Driving AUnit twice over one suite in a
      --  single run frees something twice -- "free(): invalid pointer", after
      --  the first routine passes -- so the loop belongs outside, where each
      --  pass gets its own everything.
      Which := 1;
      AUnit.Test_Suites.Add_Test (Room (1)'Access, GGUF_Case'Access);
      AUnit.Test_Suites.Add_Test (Room (1)'Access, Inference_Case'Access);
      AUnit.Test_Suites.Add_Test (Room (1)'Access, Sampling_Case'Access);
      AUnit.Test_Suites.Add_Test (Room (1)'Access, CLI_Case'Access);
      AUnit.Test_Suites.Add_Test (Room (1)'Access, Catalog_Case'Access);
      AUnit.Test_Suites.Add_Test (Room (1)'Access, Backend_Case'Access);
      AUnit.Test_Suites.Add_Test (Room (1)'Access, Accounting_Case'Access);
      AUnit.Test_Suites.Add_Test (Room (1)'Access, Template_Case'Access);
      AUnit.Test_Suites.Add_Test (Room (1)'Access, Grammar_Case'Access);

      AUnit.Test_Filters.Set_Name (Filter, Named);

      Started := Ada.Calendar.Clock;
      Ignored := Run_One (Reporter, Picked);

      Ada.Text_IO.Put_Line
        ("timed" & Duration'Image (Ada.Calendar.Clock - Started) & " s  "
         & Named);
   end Report_Routines;

end Case_Timing;
