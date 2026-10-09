with Ada.Characters.Handling;
with Ada.Strings.Fixed;

package body Model_Runner.Framework.Automation is

   use Ada.Strings.Unbounded;

   -----------------
   -- Action_Name --
   -----------------

   function Action_Name (Item : Action) return String
   is (Ada.Characters.Handling.To_Lower (Action'Image (Item)));

   ----------
   -- Read --
   ----------

   procedure Read (Line : String; Item : out Rule; Refusal : out Unbounded_String) is
      Colon : constant Natural := Ada.Strings.Fixed.Index (Line, ":");

      function Trim (Text : String) return String
      is (Ada.Strings.Fixed.Trim (Text, Ada.Strings.Both));

      --  Every action, said in a refusal.
      function Actions return String is
         Said : Unbounded_String;
      begin
         for One in Action loop
            Append (Said, (if One = Action'First then "" else ", ") & Action_Name (One));
         end loop;
         return To_String (Said);
      end Actions;
   begin
      Item := (others => <>);
      Refusal := Null_Unbounded_String;
      if Colon = 0 then
         Refusal := To_Unbounded_String
           ("an automation rule is EVENT: ACTION, not " & Trim (Line));
         return;
      end if;

      declare
         Event_Word  : constant String := Trim (Line (Line'First .. Colon - 1));
         Action_Word : constant String := Trim (Line (Colon + 1 .. Line'Last));
         Known       : Boolean := False;
      begin
         for One in Action loop
            if Action_Name (One) = Action_Word then
               Item.Act := One;
               Known := True;
            end if;
         end loop;
         if not Known then
            Refusal := To_Unbounded_String
              ("unknown automation action """ & Action_Word & """ in " & Trim (Line)
               & "; the actions are " & Actions);
            return;
         end if;

         if Event_Word = "*" then
            Item.Any := True;
            return;
         end if;
         for Kind in Events.Event_Kind loop
            if Events.Kind_Name (Kind) = Event_Word then
               Item.Event := Kind;
               return;
            end if;
         end loop;
         Refusal := To_Unbounded_String
           ("unknown event """ & Event_Word & """ in the automation rule " & Trim (Line)
            & "; an event is named as the log names it, Task_Completed, or * for any");
      end;
   end Read;

   -----------
   -- Image --
   -----------

   function Image (Item : Rule) return String
   is ((if Item.Any then "*" else Events.Kind_Name (Item.Event)) & ": " & Action_Name (Item.Act));

   -------------
   -- Matches --
   -------------

   function Matches (Item : Rule; Kind_Word : String) return Boolean
   is (Item.Any or else Events.Kind_Name (Item.Event) = Kind_Word);

   --------------
   -- Defaults --
   --------------

   function Defaults return Rule_Lists.Vector is
      use Events;
   begin
      return Result : Rule_Lists.Vector do
         Result.Append (Rule'(Any => False, Event => Requirement_Accepted, Act => Derive_Tasks));
         Result.Append (Rule'(Any => False, Event => Requirement_Revised, Act => Derive_Tasks));
         Result.Append (Rule'(Any => False, Event => Task_Completed, Act => Reevaluate_Requirements));
         Result.Append (Rule'(Any => False, Event => Source_Changed, Act => Reevaluate_Requirements));
         --  What governs the work changing its meaning takes verification
         --  from what rested on it.
         Result.Append (Rule'(Any => False, Event => Decision_Revised, Act => Reevaluate_Requirements));
         Result.Append (Rule'(Any => False, Event => Decision_Superseded, Act => Reevaluate_Requirements));
         Result.Append (Rule'(Any => False, Event => Specification_Revised, Act => Reevaluate_Requirements));
         Result.Append (Rule'(Any => False, Event => Specification_Superseded, Act => Reevaluate_Requirements));
         Result.Append (Rule'(Any => True, Event => Project_Initialized, Act => Recompute_Readiness));
      end return;
   end Defaults;

end Model_Runner.Framework.Automation;
