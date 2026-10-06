separate (Model_Runner.Framework.Work)
procedure Run_Checks
  (Host    : in out Child_Host;
   Profile : String;
   Report  : out Ada.Strings.Unbounded.Unbounded_String;
   Status  : out Model_Runner.Errors.Error_Info)
is
   Change   : Stores.Transaction;
   Evidence : Unbounded_String;
   Passed   : Boolean;
   Value    : Records.Item;
   Read     : E.Error_Info;

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
   if not May_Check (Host, Profile) then
      Status := E.Make (E.Framework_Permission_Denied);
      E.Add_Text (Status, "name", Current (Host));
      E.Add_Text (Status, "detail", "it may not run the profile " & Profile);
      return;
   end if;
   declare
      Project : constant String :=
        Ada.Directories.Containing_Directory (Stores.Root (Host.Item.all));
      Before  : constant Configurations.Value_Maps.Map := Snapshot (Project, Repository.Roots_Of (Host.Item.all));
   begin
      --  Off the network unless the agent may use it.
      --  Within the time the work has left: a check does not carry it
      --  past its bound.
      if Time_Is_Up (Host) then
         Status := E.Make (E.Framework_Limit_Exceeded);
         E.Add_Text (Status, "name", "time");
         return;
      end if;
      --  Run for its task: credited to it, where its agents work in the
      --  project itself and the checks see what it holds.
      Verification.Run_Profile
        (Host.Item.all, Change, Profile, (if Host.Apart then "" else To_String (Host.Task_Id)),
         Evidence, Passed, Status,
         Offline => not May (Host, Permissions.Use_Network, ""),
         Within  => (if Host.Bounded then Natural (Duration'Max (1.0, Time_Left (Host))) else 0));
      if E.Is_Ok (Status) then
         Stores.Commit (Host.Item.all, Change, Status);
      end if;
      if E.Is_Error (Status) then
         return;
      end if;

      --  A build writes files of its own; they are the checks', not the
      --  agent's.
      declare
         After : constant Configurations.Value_Maps.Map := Snapshot (Project, Repository.Roots_Of (Host.Item.all));
      begin
         for Position in After.Iterate loop
            declare
               Path : constant String := Configurations.Value_Maps.Key (Position);
               Now  : constant String := Configurations.Value_Maps.Element (Position);
            begin
               if not Before.Contains (Path) or else Before (Path) /= Now then
                  Host.Written.Append (Path & ASCII.HT & Now);
               end if;
            end;
         end loop;
      end;
   end;

   Report := To_Unbounded_String
     (Profile & (if Passed then " passed" else " failed") & ", "
      & To_String (Evidence));
   Stores.Read (Host.Item.all, Verification_Area, To_String (Evidence), Value, Read);
   for Index in 1 .. Records.Field_Count (Value) loop
      declare
         Field : constant String := Records.Field_Name (Value, Index);
         Parts : constant Name_Lists.Vector :=
           (if Field'Length > 6 and then Field (Field'First .. Field'First + 5) = "check."
            then Fields_Of (Records.Get (Value, Field)) else Name_Lists.Empty_Vector);
      begin
         if Natural (Parts.Length) >= 7 then
            Append (Report, ASCII.LF & Parts (1) & ": " & Parts (5));
            if Parts (5) /= "passed" and then Parts (6) = "required" then
               declare
                  Log  : Results.Result;
                  Held : E.Error_Info;
               begin
                  Results.Read (Host.Item.all, Parts (7), Log, Held);
                  if E.Is_Ok (Held) then
                     Append (Report, ASCII.LF & Tail (To_String (Log.Payload), 30));
                  end if;
               end;
            end if;
         end if;
      end;
   end loop;
end Run_Checks;
