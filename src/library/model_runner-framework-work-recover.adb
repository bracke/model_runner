separate (Model_Runner.Framework.Work)
procedure Recover
  (Item      : in out Stores.Store;
   Recovered : out Name_Lists.Vector;
   Status    : out Model_Runner.Errors.Error_Info)
is
   --  Each task put back in a change of its own, and one that cannot be is
   --  passed over for the rest, its failure the one said.
   Change : Stores.Transaction;
   First  : E.Error_Info := E.Success;

   --  The mark of what a task's files were, let go once what it says is
   --  kept: let go first, a failure after would leave it said nowhere.
   Mark_Done : Unbounded_String;

   procedure Keep (Id : String) is
      Kept : E.Error_Info;
   begin
      Stores.Commit (Item, Change, Kept);
      if E.Is_Ok (Kept) then
         Recovered.Append (Id);
         if Mark_Done /= Null_Unbounded_String then
            Files.Discard (To_String (Mark_Done));
         end if;
      else
         Change := Stores.No_Changes;
         if E.Is_Ok (First) then
            First := Kept;
         end if;
      end if;
      Mark_Done := Null_Unbounded_String;
   end Keep;

   procedure Pass_Over (Failed : E.Error_Info) is
   begin
      Change := Stores.No_Changes;
      Mark_Done := Null_Unbounded_String;
      if E.Is_Ok (First) then
         First := Failed;
      end if;
   end Pass_Over;
begin
   Recovered.Clear;
   Status := E.Success;
   for Id of Tasks.List (Item, "running") loop
      --  One with more than one workspace is left as it is: which to give
      --  up is not this to decide, and /check consistency names it.
      if Leases.Holder (Item, Lease_Of (Id)) = ""
        and then Natural (Workspaces.Every_Active (Item, Id).Length) <= 1
      then
         declare
            Agent : constant String := Holder_Record (Item, Id);
            Space : constant String := Workspaces.Active_For (Item, Id);

            --  Where it worked apart, the workspace is given up as an
            --  interrupt gives it up -- a retry starts afresh -- with
            --  what it had changed there named.
            --  Where it worked in the project itself: the files that
            --  differ from what they were when it started, left there.
            function Left_In_Project return String is
               Mark   : constant String := Before_File (Item, Id);
               Was    : Unbounded_String;
               Read   : E.Error_Info;
               Then_Map : Configurations.Value_Maps.Map;
               Named  : Unbounded_String;
               Lines  : Unbounded_String;
            begin
               --  Nothing kept, or nothing readable, is not nothing changed.
               if not Ada.Directories.Exists (Mark) then
                  return "; what it changed in the project cannot be told: what the files were"
                    & " when it started was not kept";
               end if;
               Files.Read_Text (Mark, Was, Read);
               Mark_Done := To_Unbounded_String (Mark);
               if E.Is_Error (Read) then
                  return "; what it changed in the project cannot be told: what the files were"
                    & " when it started cannot be read";
               end if;
               for Line of Lines_Of (To_String (Was)) loop
                  declare
                     Tab : constant Natural := Ada.Strings.Fixed.Index (Line, [1 => ASCII.HT]);
                  begin
                     if Tab > Line'First then
                        Then_Map.Include (Line (Line'First .. Tab - 1), Line (Tab + 1 .. Line'Last));
                     end if;
                  end;
               end loop;
               declare
                  Now : constant Configurations.Value_Maps.Map :=
                    Snapshot (Ada.Directories.Containing_Directory (Stores.Root (Item)),
                              Repository.Roots_Of (Item));
               begin
                  for Position in Now.Iterate loop
                     declare
                        Path : constant String := Configurations.Value_Maps.Key (Position);
                     begin
                        if not Then_Map.Contains (Path)
                          or else Then_Map (Path) /= Configurations.Value_Maps.Element (Position)
                        then
                           Append (Named, (if Named = Null_Unbounded_String then "" else ", ")
                                   & Path);
                           Append (Lines, Path & ASCII.LF);
                        end if;
                     end;
                  end loop;
                  for Position in Then_Map.Iterate loop
                     if not Now.Contains (Configurations.Value_Maps.Key (Position)) then
                        Append (Named, (if Named = Null_Unbounded_String then "" else ", ")
                                & Configurations.Value_Maps.Key (Position) & " (removed)");
                        Append (Lines, Configurations.Value_Maps.Key (Position) & ASCII.LF);
                     end if;
                  end loop;
               end;
               if Named = Null_Unbounded_String then
                  return "";
               end if;
               Annotate (Item, Change, Id, "changed_files", To_String (Lines));
               return Left_Words (Item, To_String (Named), Id);
            end Left_In_Project;

            function Given_Up return String is
               Named : Unbounded_String;
               Lines : Unbounded_String;
               Held  : E.Error_Info;
            begin
               if Space = "" then
                  return Left_In_Project;
               end if;
               for Path of Workspaces.Changes (Item, Space) loop
                  Append (Named, (if Named = Null_Unbounded_String then "" else ", ") & Path);
                  Append (Lines, Path & ASCII.LF);
               end loop;
               --  Kept on the task as a run's are, so its audit says them.
               if Lines /= Null_Unbounded_String then
                  Annotate (Item, Change, Id, "changed_files", To_String (Lines));
               end if;
               Workspaces.Abandon (Item, Change, Space, Held);
               return (if E.Is_Error (Held) then ""
                       else "; its workspace " & Space & " is given up"
                            & (if Named = Null_Unbounded_String then ""
                               else ", what it changed there kept in "
                                    & Ada.Directories.Simple_Name (Workspaces.Kept_Copy (Item, Space))
                                    & ": " & To_String (Named)));
            end Given_Up;
         begin
            Tasks.Move
              (Item, Change, Id, "blocked",
               "its agent " & (if Agent = "" then "" else Agent & " ")
               & "stopped without finishing" & Given_Up, Status => Status);
            if E.Is_Error (Status) then
               Pass_Over (Status);
               Status := E.Success;
               goto Next_Running;
            end if;
            if Agent /= "" then
               Stop_Children (Item, Change, Agent, "its parent stopped without finishing");
               Agent_State (Item, Change, Agent, "failed", "its agent stopped without finishing",
                            Outcome => "blocked");
            end if;
            Leases.Release (Item, Change, Lease_Of (Id), Agent, Status);
            if E.Is_Ok (Status) and then Component_Of (Item, Id) /= "" then
               Leases.Release
                 (Item, Change, Tasks.Component_Lease (Component_Of (Item, Id)), Agent, Status);
            end if;
            if E.Is_Ok (Status) and then Leases.Holder (Item, Tasks.Project_Lease) = Agent then
               Leases.Release (Item, Change, Tasks.Project_Lease, Agent, Status);
            end if;

            --  Blocked, unless the project says otherwise.
            if E.Is_Ok (Status) and then Scalar (Item, "recovery.running") = "failed" then
               Tasks.Move (Item, Change, Id, "failed", "its agent stopped without finishing",
                           Status => Status);
            elsif E.Is_Ok (Status) and then Scalar (Item, "recovery.running") = "accepted" then
               Tasks.Move (Item, Change, Id, "accepted", "", Status => Status);
            end if;
            if E.Is_Error (Status) then
               Pass_Over (Status);
               Status := E.Success;
               goto Next_Running;
            end if;
            Keep (Id);
         end;
      end if;
      <<Next_Running>>
   end loop;

   --  A task left in verification with nothing to wait for -- no work
   --  written apart waiting to be taken in -- was being verified when
   --  the harness stopped: blocked, saying so, its leases let go.
   for Id of Tasks.List (Item, "verification") loop
      if Workspaces.Active_For (Item, Id) = ""
        and then Leases.Holder (Item, Lease_Of (Id)) = ""
      then
         Tasks.Move (Item, Change, Id, "blocked",
                     "its verification stopped without finishing", Status => Status);
         if E.Is_Error (Status) then
            Pass_Over (Status);
         else
            Leases.Release (Item, Change, Lease_Of (Id), Holder_Record (Item, Id), Status);
            Keep (Id);
         end if;
         Status := E.Success;
      end if;
   end loop;
   Status := First;
end Recover;
