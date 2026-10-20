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
   --  What each of them says, as checks: A, B, in Ruling's order.
   Ruling_Says : Name_Lists.Vector;
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

   --  The checks a decision names, from its checks: A, B.
   function Checks_Of (Says : String) return Name_Lists.Vector is
      Result : Name_Lists.Vector;
      Start  : Positive := Says'First + 8;  --  past checks:
   begin
      for Index in Start .. Says'Last + 1 loop
         if Index > Says'Last or else Says (Index) = ',' then
            declare
               Name : constant String := Ada.Strings.Fixed.Trim (Says (Start .. Index - 1), Ada.Strings.Both);
            begin
               if Name /= "" then
                  Result.Append (Name);
               end if;
            end;
            Start := Index + 1;
         end if;
      end loop;
      return Result;
   end Checks_Of;

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
            Ruling_Says.Append (To_String (Held.Criteria));
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

   --  Those of the task's profile, as the work's run resolved it; and a
   --  check it does not hold from the profile that does, as the lesson
   --  was learned under one: an implementation task, run by "tests",
   --  ran none of the "checks" a lesson named.
   declare
      Found  : Name_Lists.Vector;
      Config : constant Records.Item := Configurations.Required (Host.Item.all);

      procedure Take (Text : String) is
         Start : Positive := Text'First;
         --  Each check by its label in the whole profile: one with none is
         --  numbered as Parse_Profile numbers it there, not "check" alone.
         Whole : constant Verification.Check_List := Verification.Parse_Profile (Text);
         At_Check : Natural := 0;
      begin
         for Index in Text'First .. Text'Last + 1 loop
            if Index > Text'Last or else Text (Index) in ';' | ASCII.LF then
               declare
                  Part  : constant String := Ada.Strings.Fixed.Trim (Text (Start .. Index - 1), Ada.Strings.Both);
               begin
                  if Part /= "" then
                     At_Check := At_Check + 1;
                     if At_Check <= Verification.Length (Whole) then
                        declare
                           Label : constant String := To_String (Verification.Element (Whole, At_Check).Label);
                        begin
                           if Wanted.Contains (Label) and then not Found.Contains (Label) then
                              Found.Append (Label);
                              Append (Subset, (if Length (Subset) = 0 then "" else "; ")
                                      & (if Ada.Strings.Fixed.Index (Part, ":") = 0 then Label & ": " else "")
                                      & Part);
                           end if;
                        end;
                     end if;
                  end if;
               end;
               Start := Index + 1;
            end if;
         end loop;
      end Take;
   begin
      Take (if Host.Profile_Frozen then To_String (Host.Profile_Text)
            else Records.Get (Config, "profile." & Profile));
      for Index in 1 .. Records.Field_Count (Config) loop
         exit when Natural (Found.Length) = Natural (Wanted.Length);
         declare
            Name : constant String := Records.Field_Name (Config, Index);
         begin
            --  Only of a profile the agent may run: one it may not was run
            --  for it after every write, though run_checks refused it.
            if Starts (Name, "profile.") and then Name /= "profile." & Profile
              and then May_Check (Host, Name (Name'First + 8 .. Name'Last))
            then
               Take (Records.Get (Config, Name));
            end if;
         end;
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
         Within     => Checks_Time (Host),
         Definition => To_String (Subset),
         Unkept     => True);
      if E.Is_Error (Status) or else Passed then
         return;
      end if;
      Stores.Pending (Change, Verification_Area, To_String (Evidence), Value, Staged);
      if not Staged then
         return;
      end if;
      --  The required checks that failed, each with the end of its log,
      --  and only the decisions that name one of them: a failed optional
      --  or warning check holds no change back, as it holds no work back.
      declare
         Failed  : Name_Lists.Vector;
         Details : Unbounded_String;
         Named   : Name_Lists.Vector;
      begin
         for Index in 1 .. Records.Field_Count (Value) loop
            declare
               Field : constant String := Records.Field_Name (Value, Index);
               Parts : constant Name_Lists.Vector :=
                 (if Starts (Field, "check.") then Fields_Of (Records.Get (Value, Field)) else Name_Lists.Empty_Vector);
            begin
               if Natural (Parts.Length) >= 8 and then Parts (5) /= "passed" and then Parts (6) = "required"
                 and then Parts (8) /= "warning"
               then
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
                     Failed.Append (Parts (1));
                     Append (Details, ASCII.LF & Parts (1) & ": " & Parts (5));
                     if Kept and then Records.Get (Log, "payload") /= "" then
                        Append (Details, ASCII.LF & Tail (Records.Get (Log, "payload"), 15));
                     elsif E.Is_Ok (Got) and then Length (Stored.Payload) > 0 then
                        Append (Details, ASCII.LF & Tail (To_String (Stored.Payload), 15));
                     end if;
                  end;
               end if;
            end;
         end loop;
         if Failed.Is_Empty then
            return;
         end if;
         for Index in 1 .. Natural (Ruling.Length) loop
            if (for some Label of Failed =>
                  (for some Named_Check of Name_Lists.Vector'(Checks_Of (Ruling_Says (Index))) => Named_Check = Label))
            then
               Named.Append (Ruling (Index));
            end if;
         end loop;
         Report := To_Unbounded_String
           ("but the checks " & Joined (Named) & (if Natural (Named.Length) = 1 then " holds" else " hold")
            & " every change to failed after it -- fix this before anything else:")
           & Details;
      end;
   end;
end Lesson_Checks;
