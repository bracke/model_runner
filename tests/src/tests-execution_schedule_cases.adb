with Ada.Text_IO;
with AUnit.Assertions;
with AUnit.Test_Cases;
with Model_Runner.Errors;
with Model_Runner.Llama.Execution_Schedules;

package body Tests.Execution_Schedule_Cases is

   use AUnit.Assertions;
   use type Model_Runner.Errors.Error_Code;
   package E renames Model_Runner.Errors;
   package S renames Model_Runner.Llama.Execution_Schedules;
   use type S.Execution_Step;

   procedure Reference_Order (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Item, Again : S.Schedule;
      Step, Other : S.Execution_Step;
      Status      : E.Error_Info;
      File        : Ada.Text_IO.File_Type;
      Seen_State  : array (0 .. 47) of Boolean := [others => False];
      Visits      : array (0 .. 23) of Natural := [others => 0];
   begin
      S.Build (24, (6, 18, 3), Item, Status);
      Assert (E.Is_Ok (Status) and then S.Length (Item) = 48, "three-pass schedule");
      S.Build (24, (6, 18, 3), Again, Status);
      Assert (E.Is_Ok (Status), "repeat construction");
      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, "fixtures/inkling2/schedule.txt");
      for Index in 0 .. 47 loop
         declare
            --  A literal trace transcribed from the independent reference's
            --  loop and cache offsets, not produced by this scheduler.
            Line : constant String := Ada.Text_IO.Get_Line (File);
            Expected : constant S.Execution_Step :=
              (Physical_Layer => Natural'Value (Line (4 .. 5)),
               Visit          => Positive'Value (Line (7 .. 7)),
               Logical_Layer  => Natural'Value (Line (1 .. 2)),
               State_Layer    => Natural'Value (Line (9 .. 10)));
         begin
            S.Resolve (Item, Index, Step, Status);
            Assert (E.Is_Ok (Status) and then Step = Expected, "reference step" & Index'Image);
            S.Resolve (Again, Index, Other, Status);
            Assert (E.Is_Ok (Status) and then Other = Step, "deterministic order");
            Assert (not Seen_State (Step.State_Layer), "shared runtime state between visits");
            Seen_State (Step.State_Layer) := True;
            Visits (Step.Physical_Layer) := Visits (Step.Physical_Layer) + 1;
         end;
      end loop;
      Assert (Ada.Text_IO.End_Of_File (File), "unexpected reference rows");
      Ada.Text_IO.Close (File);
      Assert ((for all Used of Seen_State => Used), "state slot missing");
      for Physical in Visits'Range loop
         Assert (Visits (Physical) = (if Physical in 6 .. 17 then 3 else 1), "physical weight ownership");
      end loop;
   end Reference_Order;

   procedure Single_Pass (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Item   : S.Schedule;
      Step   : S.Execution_Step;
      Status : E.Error_Info;
   begin
      for Count in 1 .. Model_Runner.Llama.Max_Block_Count loop
         S.Build (Count, Item, Status);
         Assert (E.Is_Ok (Status) and then S.Length (Item) = Count, "single-pass count");
         for Index in 0 .. Count - 1 loop
            S.Resolve (Item, Index, Step, Status);
            Assert (E.Is_Ok (Status) and then Step = (Index, 1, Index, Index), "single-pass identity");
         end loop;
      end loop;
   end Single_Pass;

   procedure Rejected_Input (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Item   : S.Schedule;
      Step   : S.Execution_Step;
      Status : E.Error_Info;

      procedure Reject (Count : Natural; Loop_Config : S.Loop_Configuration; Bound : Natural := 512) is
      begin
         S.Build (24, (6, 18, 3), Item, Status);
         S.Build (Count, Loop_Config, Item, Status, Bound);
         Assert (E.Is_Error (Status) and then S.Length (Item) = 0, "invalid order survived construction");
         Assert (Status.Code = E.Arch_Invalid_Metadata and then E.Text_Of (Status, "key") /= "",
                 "invalid order lacks a renderable diagnostic key");
         S.Resolve (Item, 0, Step, Status);
         Assert (Status.Code = E.Arch_Invalid_Metadata, "invalid order resolved a step");
      end Reject;
   begin
      Reject (0, (0, 0, 1));
      Reject (Natural'Last, (6, 18, 3));
      Reject (24, (18, 6, 3));
      Reject (24, (6, 6, 3));
      Reject (24, (6, 25, 3));
      Reject (24, (Natural'Last, Natural'Last, 3));
      Reject (24, (6, 18, Positive'Last));
      Reject (24, (6, 18, 3), 47);
      Reject (24, (6, 18, 3), 0);
      Reject (513, (0, 513, 1), Natural'Last);
      S.Resolve (Item, Natural'Last, Step, Status);
      Assert (Status.Code = E.Arch_Invalid_Metadata, "unbounded step resolved");
      Assert (Step = (0, 1, 0, 0), "failed resolution retained prior identities");
   end Rejected_Input;

   procedure Region_Boundaries (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Item   : S.Schedule;
      Step   : S.Execution_Step;
      Status : E.Error_Info;
   begin
      S.Build (1, (0, 1, 512), Item, Status);
      Assert (E.Is_Ok (Status) and then S.Length (Item) = 512, "whole-stack loop at capacity");
      S.Resolve (Item, 511, Step, Status);
      Assert (E.Is_Ok (Status) and then Step = (0, 512, 511, 511), "last allowed visit");
      S.Resolve (Item, 512, Step, Status);
      Assert (E.Is_Error (Status), "step past end accepted");
      S.Build (24, (0, 24, 1), Item, Status);
      Assert (E.Is_Ok (Status) and then S.Length (Item) = 24, "one visit with no prelude or epilogue");
      S.Build (24, (6, 18, 3), Item, Status, 48);
      Assert (E.Is_Ok (Status) and then S.Length (Item) = 48, "exact caller budget rejected");
      S.Resolve (Item, 42, Step, Status);
      Assert (E.Is_Ok (Status) and then Step = (18, 1, 42, 18), "epilogue identities confused");
   end Region_Boundaries;

   overriding function Name (T : Case_Type) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("execution schedules");
   end Name;

   overriding procedure Register_Tests (T : in out Case_Type) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine (T, Reference_Order'Access, "Inkling reference order and state identity");
      Register_Routine (T, Single_Pass'Access, "ordinary decoder identity");
      Register_Routine (T, Rejected_Input'Access, "invalid regions, overflow and stale orders");
      Register_Routine (T, Region_Boundaries'Access, "loop boundaries and caller limits");
   end Register_Tests;

end Tests.Execution_Schedule_Cases;
