with Ada.Calendar.Formatting;
with Ada.Characters.Handling;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Hostkit.Process;

package body Model_Runner.Framework is

   use type Interfaces.Unsigned_64;

   --------------------
   -- Directory_Name --
   --------------------

   function Directory_Name (Where : Area) return String is
   begin
      case Where is
         when Project_Area      => return "project";
         when Config_Area       => return "config";
         when Specs_Area        => return "specs";
         when Requirements_Area => return "requirements";
         when Decisions_Area    => return "decisions";
         when Tasks_Area        => return "tasks";
         when Runtime_Area      => return "runtime";
         when Results_Area      => return "results";
         when Events_Area       => return "events";
         when Verification_Area => return "verification";
         when Invocations_Area  => return "invocations";
         when Workspaces_Area   => return "workspaces";
         when Indexes_Area      => return "indexes";
         when Derivations_Area  => return "derivations";
         when Observations_Area => return "observations";
      end case;
   end Directory_Name;

   --------------
   -- Class_Of --
   --------------

   function Class_Of (Where : Area) return State_Class is
   begin
      case Where is
         when Project_Area
            | Config_Area
            | Specs_Area
            | Requirements_Area
            | Decisions_Area
            | Tasks_Area =>
            return Authored_State;

         when Runtime_Area | Workspaces_Area =>
            return Runtime_State;

         when Results_Area
            | Events_Area
            | Verification_Area
            | Invocations_Area =>
            return Historical_State;

         when Observations_Area =>
            return Observational_State;

         when Indexes_Area | Derivations_Area =>
            return Derived_State;
      end case;
   end Class_Of;

   --------------------
   -- Portability_Of --
   --------------------

   function Portability_Of (Where : Area) return Portability is
   begin
      case Class_Of (Where) is
         when Authored_State | Historical_State | Observational_State =>
            return Repository_Portable;
         when Runtime_State                     => return Machine_Local;
         when Derived_State                     => return Derived_Cache;
      end case;
   end Portability_Of;

   --------------
   -- Lines_Of --
   --------------

   function Process_Line (Process_Id : Integer) return String is
      Identity : constant String := Hostkit.Process.Identity_Of (Process_Id);
      Image    : constant String := Ada.Strings.Fixed.Trim (Integer'Image (Process_Id), Ada.Strings.Both);
   begin
      return (if Identity = "" then Image else Image & " " & Identity);
   end Process_Line;

   function Standing_Of (Line : String) return Process_Standing is
      use type Hostkit.Process.Presence;
      Text  : constant String := Ada.Strings.Fixed.Trim (Line, Ada.Strings.Both);
      Space : constant Natural := Ada.Strings.Fixed.Index (Text & " ", " ");
      Id    : constant String := Text (Text'First .. Space - 1);
      Kept  : constant String :=
        (if Space < Text'Last then Ada.Strings.Fixed.Trim (Text (Space + 1 .. Text'Last), Ada.Strings.Both)
         else "");
   begin
      if Id'Length not in 1 .. 10 or else (for some C of Id => C not in '0' .. '9')
        or else Long_Long_Integer'Value (Id) > Long_Long_Integer (Integer'Last)
      then
         return Not_Known;
      end if;
      declare
         Pid      : constant Integer := Integer'Value (Id);
         Presence : constant Hostkit.Process.Presence := Hostkit.Process.Presence_Of (Pid);
      begin
         if Presence = Hostkit.Process.Absent then
            return Other_Process;
         elsif Presence /= Hostkit.Process.Present or else Kept = "" then
            return Not_Known;
         end if;
         declare
            Now : constant String := Hostkit.Process.Identity_Of (Pid);
         begin
            return (if Now = "" then Not_Known elsif Now = Kept then Same_Process else Other_Process);
         end;
      end;
   end Standing_Of;

   function Later (Name, Than : String) return Boolean is
      --  The first run of digits in a name, as a number.
      function Number_In (Text : String) return Natural is
         Value : Natural := 0;
         Seen  : Boolean := False;
      begin
         for C of Text loop
            if C in '0' .. '9' then
               Seen := True;
               exit when Value > Natural'Last / 10 - 9;
               Value := Value * 10 + (Character'Pos (C) - Character'Pos ('0'));
            elsif Seen then
               exit;
            end if;
         end loop;
         return Value;
      end Number_In;
   begin
      return Than = ""
        or else Number_In (Name) > Number_In (Than)
        or else (Number_In (Name) = Number_In (Than) and then Name > Than);
   end Later;

   function Lines_Of (Text : String) return Name_Lists.Vector is
      Result : Name_Lists.Vector;
      Start  : Natural := Text'First;
   begin
      for Index in Text'First .. Text'Last + 1 loop
         if Index > Text'Last or else Text (Index) = ASCII.LF then
            if Index > Start then
               Result.Append (Text (Start .. Index - 1));
            end if;
            Start := Index + 1;
         end if;
      end loop;
      return Result;
   end Lines_Of;

   -------------
   -- Nearest --
   -------------

   function Nearest (Word : String; Among : Name_Lists.Vector) return String is
      use Ada.Strings.Unbounded;
      function Lower (Text : String) return String
        renames Ada.Characters.Handling.To_Lower;

      --  How many letters apart two names are: added, taken out, changed,
      --  or two side by side swapped -- /taks is a letter from /task.
      function Distance (Left, Right : String) return Natural is
         Cost : array (0 .. Left'Length, 0 .. Right'Length) of Natural;
      begin
         for I in Cost'Range (1) loop
            Cost (I, 0) := I;
         end loop;
         for J in Cost'Range (2) loop
            Cost (0, J) := J;
         end loop;
         for I in 1 .. Left'Length loop
            for J in 1 .. Right'Length loop
               declare
                  Same : constant Boolean := Left (Left'First + I - 1) = Right (Right'First + J - 1);
               begin
                  Cost (I, J) := Natural'Min
                    (Natural'Min (Cost (I - 1, J) + 1, Cost (I, J - 1) + 1),
                     Cost (I - 1, J - 1) + (if Same then 0 else 1));
                  if I > 1 and then J > 1
                    and then Left (Left'First + I - 1) = Right (Right'First + J - 2)
                    and then Left (Left'First + I - 2) = Right (Right'First + J - 1)
                  then
                     Cost (I, J) := Natural'Min (Cost (I, J), Cost (I - 2, J - 2) + 1);
                  end if;
               end;
            end loop;
         end loop;
         return Cost (Left'Length, Right'Length);
      end Distance;

      Best  : Natural := Natural'Last;
      Found : Unbounded_String;
      --  A letter or two, and no more than a third of the word.
      Limit : constant Natural := Natural'Max (1, Natural'Min (2, Word'Length / 3));
   begin
      --  The same name in other letters' case: that one.
      for Name of Among loop
         if Lower (Name) = Lower (Word) and then Name /= Word then
            return Name;
         end if;
      end loop;
      --  The one name it begins, first: ada-lib is ada-library, however
      --  near another's letters are.
      declare
         Starting : Natural := 0;
         Named    : Unbounded_String;
      begin
         if Word'Length >= 3 then
            for Name of Among loop
               if Name'Length > Word'Length
                 and then Lower (Name (Name'First .. Name'First + Word'Length - 1)) = Lower (Word)
               then
                  Starting := Starting + 1;
                  Named := To_Unbounded_String (Name);
               end if;
            end loop;
            if Starting = 1 then
               return To_String (Named);
            end if;
         end if;
      end;
      for Name of Among loop
         declare
            Apart : constant Natural := Distance (Lower (Word), Lower (Name));
         begin
            if Apart <= Limit and then Apart < Best and then Lower (Word) /= Lower (Name) then
               Best := Apart;
               Found := To_Unbounded_String (Name);
            end if;
         end;
      end loop;
      return To_String (Found);
   end Nearest;

   ---------------
   -- Timestamp --
   ---------------

   function Timestamp return String
   is (Timestamp_After (0));

   ---------------------
   -- Timestamp_After --
   ---------------------

   function Timestamp_After (Seconds : Natural) return String is
      use type Ada.Calendar.Time;
      Text : String :=
        Ada.Calendar.Formatting.Image
          (Ada.Calendar.Clock + Duration (Seconds));
   begin
      Text (Text'First + 10) := 'T';
      return Text & "Z";
   end Timestamp_After;

   ----------
   -- Hash --
   ----------

   function Hash (Text : String) return Interfaces.Unsigned_64 is
      Value : Interfaces.Unsigned_64 := 16#CBF2_9CE4_8422_2325#;
   begin
      for Char of Text loop
         Value := Value xor Interfaces.Unsigned_64 (Character'Pos (Char));
         Value := Value * 16#0000_0100_0000_01B3#;
      end loop;
      return Value;
   end Hash;

   -----------------
   -- Fingerprint --
   -----------------

   function Fingerprint (Text : String) return String is
      Digits_Of : constant String := "0123456789abcdef";
      Value     : Interfaces.Unsigned_64 := Hash (Text);
      Result    : String (1 .. 16);
   begin
      for Index in reverse Result'Range loop
         Result (Index) := Digits_Of (Natural (Value and 16#F#) + 1);
         Value := Interfaces.Shift_Right (Value, 4);
      end loop;
      return Result;
   end Fingerprint;

end Model_Runner.Framework;
