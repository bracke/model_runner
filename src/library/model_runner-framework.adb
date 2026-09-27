with Ada.Calendar.Formatting;

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

         when Indexes_Area =>
            return Derived_State;
      end case;
   end Class_Of;

   --------------------
   -- Portability_Of --
   --------------------

   function Portability_Of (Where : Area) return Portability is
   begin
      case Class_Of (Where) is
         when Authored_State | Historical_State => return Repository_Portable;
         when Runtime_State                     => return Machine_Local;
         when Derived_State                     => return Derived_Cache;
      end case;
   end Portability_Of;

   --------------
   -- Lines_Of --
   --------------

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
