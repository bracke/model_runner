separate (Model_Runner.Framework.Work)
procedure Lesson_Checks
  (Host   : in out Child_Host;
   Report : out Ada.Strings.Unbounded.Unbounded_String)
is
   Profile  : constant String := Task_Profile (Host);
   Defined  : Records.Item;
   Read     : E.Error_Info;
   Wanted   : Name_Lists.Vector;
   Ruling   : Name_Lists.Vector;
   Subset   : Unbounded_String;

   function Starts (Text, Prefix : String) return Boolean
   is (Text'Length >= Prefix'Length and then Text (Text'First .. Text'First + Prefix'Length - 1) = Prefix);

   function Joined (Names : Name_Lists.Vector) return String is
      Text : Unbounded_String;
   begin
      for Name of Names loop
         Append (Text, (if Length (Text) = 0 then "" else ", ") & Name);
      end loop;
      return To_String (Text);
   end Joined;

   --  The last lines of a text, enough to see an error by.
   function Tail (Text : String; Count : Positive) return String is
      Seen : Natural := 0;
   begin
      for Index in reverse Text'Range loop
         if Text (Index) = ASCII.LF and then Index < Text'Last then
            Seen := Seen + 1;
            if Seen = Count then
               return Text (Index + 1 .. Text'Last);
            end if;
         end if;
      end loop;
      return Text;
   end Tail;
begin
   Report := Null_Unbounded_String;
   if Profile = "" or else not May_Check (Host, Profile) then
      return;
   end if;
   Tasks.Definition (Host.Item.all, To_String (Host.Task_Id), Defined, Read);
   if E.Is_Error (Read) then
      return;
   end if;
   --  The checks each such decision names, as checks: A, B.
   for Id of Intent.Applicable_Decisions (Host.Item.all, Records.Get (Defined, "component")) loop
      declare
         Held : Intent.Entity;
         Got  : E.Error_Info;
      begin
         Intent.Read (Host.Item.all, Intent.Decision, Id, Held, Got);
         if E.Is_Ok (Got) and then To_String (Held.Source) = "harness"
           and then Starts (To_String (Held.Criteria), "checks: ")
         then
            Ruling.Append (Id);
            declare
               Names : constant String := To_String (Held.Criteria);
               Start : Positive := Names'First + 8;  --  past checks:
            begin
               for Index in Start .. Names'Last + 1 loop
                  if Index > Names'Last or else Names (Index) = ',' then
                     declare
                        Name : constant String :=
                          Ada.Strings.Fixed.Trim (Names (Start .. Index - 1), Ada.Strings.Both);
                     begin
                        if Name /= "" and then not Wanted.Contains (Name) then
                           Wanted.Append (Name);
                        end if;
                     end;
                     Start := Index + 1;
                  end if;
               end loop;
            end;
         end if;
      end;
   end loop;
   if Wanted.Is_Empty then
      return;
   end if;

   --  Those of the task's profile, as the work's run resolved it.
   declare
      Text  : constant String :=
        (if Host.Profile_Frozen then To_String (Host.Profile_Text)
         else Records.Get (Configurations.Required (Host.Item.all), "profile." & Profile));
      Start : Positive := Text'First;
   begin
      for Index in Text'First .. Text'Last + 1 loop
         if Index > Text'Last or else Text (Index) in ';' | ASCII.LF then
            declare
               Part  : constant String := Ada.Strings.Fixed.Trim (Text (Start .. Index - 1), Ada.Strings.Both);
               Check : constant Verification.Check_List := Verification.Parse_Profile (Part);
            begin
               if Part /= "" and then Verification.Length (Check) = 1
                 and then Wanted.Contains (To_String (Verification.Element (Check, 1).Label))
               then
                  Append (Subset, (if Length (Subset) = 0 then "" else "; ") & Part);
               end if;
            end;
            Start := Index + 1;
         end if;
      end loop;
   end;
   if Length (Subset) = 0 or else Time_Is_Up (Host) then
      return;
   end if;

   declare
      Change   : Stores.Transaction;
      Evidence : Unbounded_String;
      Passed   : Boolean;
      Status   : E.Error_Info;
      Value    : Records.Item;
      Staged   : Boolean;
   begin
      Verification.Run_Profile
        (Host.Item.all, Change, Profile, To_String (Host.Task_Id), Evidence, Passed, Status,
         Offline    => not May (Host, Permissions.Use_Network, ""),
         Workspace  => (if Host.Apart then To_String (Host.Tree) else ""),
         Within     => (if Host.Bounded then Natural (Duration'Max (1.0, Time_Left (Host))) else 0),
         Definition => To_String (Subset),
         Unkept     => True);
      if E.Is_Error (Status) or else Passed then
         return;
      end if;
      Stores.Pending (Change, Verification_Area, To_String (Evidence), Value, Staged);
      if not Staged then
         return;
      end if;
      Report := To_Unbounded_String
        ("but the checks " & Joined (Ruling) & " holds every change to failed after it -- fix this before"
         & " anything else:");
      for Index in 1 .. Records.Field_Count (Value) loop
         declare
            Field : constant String := Records.Field_Name (Value, Index);
            Parts : constant Name_Lists.Vector :=
              (if Starts (Field, "check.") then Fields_Of (Records.Get (Value, Field)) else Name_Lists.Empty_Vector);
         begin
            if Natural (Parts.Length) >= 7 and then Parts (5) /= "passed" then
               declare
                  Log    : Records.Item;
                  Kept   : Boolean;
                  Stored : Results.Result;
                  Got    : E.Error_Info;
               begin
                  --  Staged where it is new; one the same is kept already.
                  Stores.Pending (Change, Results_Area, Parts (7), Log, Kept);
                  if not Kept or else Records.Get (Log, "payload") = "" then
                     Results.Read (Host.Item.all, Parts (7), Stored, Got);
                  end if;
                  Append (Report, ASCII.LF & Parts (1) & ": " & Parts (5));
                  if Kept and then Records.Get (Log, "payload") /= "" then
                     Append (Report, ASCII.LF & Tail (Records.Get (Log, "payload"), 15));
                  elsif E.Is_Ok (Got) and then Length (Stored.Payload) > 0 then
                     Append (Report, ASCII.LF & Tail (To_String (Stored.Payload), 15));
                  end if;
               end;
            end if;
         end;
      end loop;
   end;
end Lesson_Checks;
