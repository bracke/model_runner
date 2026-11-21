with Ada.Real_Time;

with Hostkit.Spawn.Supervision;

package body Child_Guards is

   use type Ada.Real_Time.Time;

   --  A finalizer must not raise while an AUnit assertion is already leaving
   --  its scope.  In the exceptional case where the bounded local stop cannot
   --  collect a child, transfer the handle to a longer-lived reaper instead of
   --  forgetting it.  The ordinary path never reaches this task.
   task Reaper is
      entry Adopt
        (Child : Hostkit.Spawn.Process_Handle;
         Taken : out Boolean);
   end Reaper;

   task body Reaper is
      Max_Pending : constant := 128;
      type Process_Array is
        array (Positive range 1 .. Max_Pending) of
          Hostkit.Spawn.Process_Handle;
      Pending : Process_Array := [others => Hostkit.Spawn.Invalid_Process];
      Used    : Natural := 0;

      procedure Receive
        (Child : Hostkit.Spawn.Process_Handle;
         Taken : out Boolean) is
      begin
         Taken := Hostkit.Spawn.Is_Valid (Child) and then Used < Max_Pending;
         if Taken then
            Used := Used + 1;
            Pending (Used) := Child;
         end if;
      end Receive;

      procedure Reap is
         Result : Hostkit.Spawn.Status;
         Index  : Positive := 1;
      begin
         while Index <= Used loop
            if Hostkit.Spawn.Supervision.Has_Ended
                 (Pending (Index), Result)
            then
               Hostkit.Spawn.Release (Pending (Index));
               Pending (Index) := Pending (Used);
               Pending (Used) := Hostkit.Spawn.Invalid_Process;
               Used := Used - 1;
            else
               declare
                  Sent : constant Boolean :=
                    Hostkit.Spawn.Supervision.Stop_Now (Pending (Index));
                  pragma Unreferenced (Sent);
               begin
                  Index := Index + 1;
               end;
            end if;
         end loop;
      exception
         when others =>
            null;
      end Reap;
   begin
      loop
         if Used = 0 then
            select
               accept Adopt
                 (Child : Hostkit.Spawn.Process_Handle;
                  Taken : out Boolean)
               do
                  Receive (Child, Taken);
               end Adopt;
            or
               terminate;
            end select;
         else
            select
               accept Adopt
                 (Child : Hostkit.Spawn.Process_Handle;
                  Taken : out Boolean)
               do
                  Receive (Child, Taken);
               end Adopt;
            or
               delay 0.050;
            end select;
            Reap;
         end if;
      end loop;
   end Reaper;

   function Stop_And_Reap (Item : in out Guard) return Boolean is
      Result   : Hostkit.Spawn.Status;
      Ended    : Boolean;
      Deadline : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (5.0);
   begin
      if not Hostkit.Spawn.Is_Valid (Item.Child) then
         return True;
      end if;

      Ended := Hostkit.Spawn.Supervision.Has_Ended (Item.Child, Result);
      if not Ended then
         declare
            Sent : constant Boolean :=
              Hostkit.Spawn.Supervision.Stop_Now (Item.Child);
            pragma Unreferenced (Sent);
         begin
            null;
         end;

         loop
            Ended := Hostkit.Spawn.Supervision.Has_Ended
              (Item.Child, Result);
            exit when Ended;
            exit when Ada.Real_Time.Clock >= Deadline;
            delay 0.010;
         end loop;
      end if;

      --  Release is safe only once the child has been collected.  If a host
      --  refused even the forced stop, retaining an OS handle is preferable
      --  to releasing a live process from the guard's authority.
      if Ended then
         Hostkit.Spawn.Release (Item.Child);
      end if;
      return Ended;
   exception
      when others =>
         return False;
   end Stop_And_Reap;

   procedure Watch
     (Item  : in out Guard;
      Child : Hostkit.Spawn.Process_Handle) is
   begin
      --  Never overwrite a process that cleanup could not collect: doing so
      --  would lose the only handle by which the test can stop it.
      if Hostkit.Spawn.Is_Valid (Item.Child) then
         raise Program_Error with "child guard is already watching a process";
      end if;
      Item.Child := Child;
   end Watch;

   function Wait
     (Item    : in out Guard;
      Timeout : Duration;
      Result  : out Hostkit.Spawn.Status) return Boolean
   is
      Deadline : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock
        + Ada.Real_Time.To_Time_Span (Duration'Max (0.0, Timeout));
   begin
      Result := (others => <>);
      if not Hostkit.Spawn.Is_Valid (Item.Child) then
         return False;
      end if;

      loop
         if Hostkit.Spawn.Supervision.Has_Ended (Item.Child, Result) then
            Hostkit.Spawn.Release (Item.Child);
            return True;
         end if;
         exit when Ada.Real_Time.Clock >= Deadline;
         delay 0.010;
      end loop;
      return False;
   end Wait;

   overriding procedure Finalize (Item : in out Guard) is
      Taken : Boolean := False;
   begin
      if not Stop_And_Reap (Item) then
         Reaper.Adopt (Item.Child, Taken);
         if Taken then
            Item.Child := Hostkit.Spawn.Invalid_Process;
         end if;
      end if;
   exception
      --  Never replace the assertion or exception that caused finalization.
      --  Stop_And_Reap already made the bounded best effort before this path.
      when others =>
         null;
   end Finalize;

end Child_Guards;
