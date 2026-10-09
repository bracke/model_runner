separate (Model_Runner.Framework.Work)
procedure Reevaluate
  (Item   : in out Stores.Store;
   Said   : out Name_Lists.Vector;
   Status : out Model_Runner.Errors.Error_Info)
is
   Change : Stores.Transaction;
   Became : Name_Lists.Vector;
   Moved  : Name_Lists.Vector;
   Was    : Configurations.Value_Maps.Map;
begin
   Said.Clear;
   for Id of Intent.List (Item, Intent.Requirement) loop
      Was.Include (Id, Intent.State_Of (Item, Intent.Requirement, Id));
   end loop;
   Tasks.Recompute_Readiness (Item, Change, Became, Status);
   if E.Is_Ok (Status) then
      Verification.Reevaluate_Requirements (Item, Change, Moved, Status);
   end if;
   if E.Is_Ok (Status) then
      Stores.Commit (Item, Change, Status);
   end if;
   --  Only a state that changed is said, with from and to, and what
   --  judges it again.
   for Id of Moved loop
      if not Was.Contains (Id) or else Was (Id) /= Intent.State_Of (Item, Intent.Requirement, Id)
      then
         declare
            Now    : constant String := Intent.State_Of (Item, Intent.Requirement, Id);
            Before : constant String := (if Was.Contains (Id) then Configurations.Value_Maps.Element (Was, Id)
                                         else "");
            function Rank (State : String) return Natural
            is (if State = "verified" then 3 elsif State = "implemented" then 2
                elsif State = Tasks.Accepted then 1 else 0);
         begin
            --  Said as the way it went: back, because what verified it
            --  no longer covers it; or on, because now something does.
            if Before /= "" and then Rank (Now) < Rank (Before) then
               Said.Append (Id & " drops back from " & Before & " to " & Now
                            & ": what verified it no longer covers it as it stands -- it or its code"
                            & " changed; /check " & Id & " judges it again");
            else
               Said.Append (Id & " is " & Now & " now" & (if Before = "" then "" else ", from " & Before)
                            & ": what it is judged by covers it as it stands");
            end if;
         end;
      end if;
   end loop;
end Reevaluate;
