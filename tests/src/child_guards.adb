with Ada.Real_Time;

with Hostkit.Spawn.Supervision;

package body Child_Guards is

   use type Ada.Real_Time.Time;

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
   begin
      if not Stop_And_Reap (Item) then
         --  A bounded finalizer cannot safely forget a live child. Make the
         --  cleanup failure visible instead of silently losing its handle.
         raise Program_Error with "child guard could not stop and reap process";
      end if;
   end Finalize;

end Child_Guards;
