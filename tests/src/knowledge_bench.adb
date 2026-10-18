with Ada.Calendar;
with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

with Model_Runner.Errors;
with Model_Runner.Framework.Configurations;
with Model_Runner.Framework.Context;
with Model_Runner.Framework.Derivations;
with Model_Runner.Framework.Observations;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Stores;
with Model_Runner.Framework.Tasks;
with Model_Runner.Framework.Templates;
with Model_Runner.Framework.Views;

package body Knowledge_Bench is

   use Ada.Strings.Unbounded;
   use type Ada.Calendar.Time;

   package E renames Model_Runner.Errors;
   package S renames Model_Runner.Framework.Stores;
   package Tk renames Model_Runner.Framework.Tasks;
   package Tp renames Model_Runner.Framework.Templates;
   package Cf renames Model_Runner.Framework.Configurations;
   package Cx renames Model_Runner.Framework.Context;
   package Dv renames Model_Runner.Framework.Derivations;
   package Ob renames Model_Runner.Framework.Observations;

   LF : constant Character := ASCII.LF;

   function Image (Value : Natural) return String
   is (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   --  Milliseconds, to a tenth.
   function Millis (Took : Duration) return String is
      Tenths : constant Natural := Natural (Took * 10_000.0);
   begin
      return Image (Tenths / 10) & "." & Image (Tenths mod 10) & " ms";
   end Millis;

   procedure Put (File, Text : String) is
      Out_File : Ada.Text_IO.File_Type;
   begin
      Ada.Text_IO.Create (Out_File, Ada.Text_IO.Out_File, File);
      Ada.Text_IO.Put (Out_File, Text);
      Ada.Text_IO.Close (Out_File);
   end Put;

   procedure Refuse (What : String; Status : E.Error_Info) is
   begin
      raise Program_Error with "knowledge-bench: " & What & ": " & E.Error_Code'Image (Status.Code);
   end Refuse;

   ---------
   -- Run --
   ---------

   procedure Run (Tasks, Files, Observations : Positive) is
      Root    : constant String := Ada.Directories.Full_Name ("obj/knowledge-bench");
      Store   : S.Store;
      Change  : S.Transaction;
      Status  : E.Error_Info;
      First   : Unbounded_String;
      Other   : Unbounded_String;
      Kept    : Unbounded_String;
      Fresh   : Boolean;
      Model   : constant Cx.Model_Profile :=
        (Id => To_Unbounded_String ("bench"), Context_Limit => 60_000, Output_Reserve => 512, others => <>);

      --  The best of three of an operation.
      function Best (Act : not null access procedure) return Duration is
         Least : Duration := Duration'Last;
      begin
         for Round in 1 .. 3 loop
            declare
               Began : constant Ada.Calendar.Time := Ada.Calendar.Clock;
            begin
               Act.all;
               Least := Duration'Min (Least, Ada.Calendar.Clock - Began);
            end;
         end loop;
         return Least;
      end Best;

      procedure Effective is
         View : Model_Runner.Framework.Records.Item;
      begin
         Tk.Effective (Store, To_String (First), View, Status);
      end Effective;

      procedure Built_Again is
         Made : Cx.Built;
      begin
         Cx.Build (Store, To_String (First), Model, Made, Status);
      end Built_Again;

      procedure Worked_Out is
         Made : Cx.Built;
      begin
         Dv.Forget;
         Cx.Build (Store, To_String (First), Model, Made, Status);
      end Worked_Out;

      procedure Pages is
      begin
         Model_Runner.Framework.Views.Refresh (Store);
      end Pages;

      Recording : Duration;
   begin
      if Ada.Directories.Exists (Root) then
         Ada.Directories.Delete_Tree (Root);
      end if;
      Ada.Directories.Create_Path (Root & "/src");
      declare
         Registry : Tp.Registry;
         Template : Tp.Template;
         Composed : Tp.Composition;
         Given    : Cf.Value_Maps.Map;
         Planned  : Cf.Plan;
         Done     : Cf.Outcome;
      begin
         Tp.Parse ("template = work" & LF & "name = W" & LF & "description = D" & LF & "version = 1" & LF
                   & "task_kind implementation = component, requirements?, notes?" & LF
                   & "task_kind analysis = estimate?" & LF
                   & "map task_field.estimate = text" & LF
                   & "scalar task.profile.implementation = tests" & LF
                   & "profile tests = run the tests" & LF, "memory", Template, Status);
         Tp.Add (Registry, Template);
         Tp.Compose (Registry, "work", Composed, Status);
         Cf.Prepare (Composed, Root, Given, Planned, Status);
         Cf.Initialize (Store, Root, Planned, Done, Status);
         if E.Is_Error (Status) then
            Refuse ("the project was not made", Status);
         end if;
      end;

      for Index in 1 .. Files loop
         Put (Root & "/src/unit_" & Image (Index) & ".ads",
              "package Unit_" & Image (Index) & " is" & LF & "   procedure P (X : Integer);" & LF
              & "end Unit_" & Image (Index) & ";" & LF);
      end loop;
      for Index in 1 .. Tasks loop
         declare
            Given : Tk.Field_Map;
         begin
            Given.Include ("title", "Task " & Image (Index) & " in src/unit_1.ads");
            Given.Include ("kind", "implementation");
            Given.Include ("component", "unit");
            Tk.Create (Store, Change, Given, "user", "", Other, Status);
         end;
         if Index = 1 then
            First := Other;
         end if;
         if Index mod 50 = 0 or else Index = Tasks then
            S.Commit (Store, Change, Status);
            if E.Is_Error (Status) then
               Refuse ("the tasks were not made", Status);
            end if;
         end if;
      end loop;
      declare
         Began : constant Ada.Calendar.Time := Ada.Calendar.Clock;
      begin
         for Index in 1 .. Observations loop
            declare
               Said : Ob.Draft;
            begin
               Said.Kind := Ob.Finding;
               Said.Summary := To_Unbounded_String
                 ("finding " & Image (Index) & " about unit " & Image (Index * 7) & " and its procedure P");
               Said.Files.Append ("src/unit_" & Image ((Index mod Files) + 1) & ".ads");
               Change := S.No_Changes;
               Ob.Record_Observation
                 (Store, Change, Said, (Producer => Ob.Harness_Producer, Task_Id => First, others => <>),
                  Kept, Fresh, Status);
               S.Commit (Store, Change, Status);
            end;
         end loop;
         Recording := (Ada.Calendar.Clock - Began) / Observations;
      end;

      --  Old enough that what is read of each file is remembered.
      delay 2.5;
      Ada.Text_IO.Put_Line ("knowledge-bench: " & Image (Tasks) & " tasks, " & Image (Files) & " source files, "
                            & Image (Observations) & " observations; the best of three");
      Ada.Text_IO.Put_Line ("  effective task:                     " & Millis (Best (Effective'Access)));
      Ada.Text_IO.Put_Line ("  context, retrieval worked out:      " & Millis (Best (Worked_Out'Access)));
      Built_Again;
      Ada.Text_IO.Put_Line ("  context, retrieval used again:      " & Millis (Best (Built_Again'Access)));
      Ada.Text_IO.Put_Line ("  recording an observation, average:  " & Millis (Recording));
      Pages;
      Ada.Text_IO.Put_Line ("  pages made again, nothing changed:  " & Millis (Best (Pages'Access)));
      S.Close (Store);
   end Run;

end Knowledge_Bench;
