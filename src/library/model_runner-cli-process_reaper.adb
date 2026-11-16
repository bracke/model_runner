with Ada.Containers;
with Ada.Containers.Vectors;
with Ada.Directories;
with Ada.Strings.Unbounded;
with Ada.Task_Identification;

with Hostkit.Signals;
with Hostkit.Spawn.Supervision;

package body Model_Runner.CLI.Process_Reaper is

   use Ada.Strings.Unbounded;

   type Held_Process is record
      Child  : Hostkit.Spawn.Process_Handle := Hostkit.Spawn.Invalid_Process;
      Output : Unbounded_String;
      Ticks  : Natural := 0;
      Remove_Tries : Natural := 0;
   end record;

   package Held_Processes is new Ada.Containers.Vectors (Positive, Held_Process);

   --  Long enough for an asynchronously terminated process tree to close its
   --  inherited handles, but bounded so a permanent permissions or filesystem
   --  failure does not leave an ever-growing polling list.
   Most_Remove_Tries : constant := 200;

   task Reaper is
      entry Take
        (Child  : in out Hostkit.Spawn.Process_Handle;
         Output : String);
   end Reaper;

   task body Reaper is
      Held : Held_Processes.Vector;

      procedure Stop_Group (Child : Hostkit.Spawn.Process_Handle) is
         Group : constant Integer := Hostkit.Spawn.Group_Id (Child);
      begin
         if Group > 1 then
            declare
               Sent : constant Boolean := Hostkit.Signals.Send_To_Group
                 (Group, Hostkit.Signals.Signal_Kill);
               pragma Unreferenced (Sent);
            begin
               null;
            end;
         end if;
      exception
         when others =>
            null;
      end Stop_Group;

      function Collected (Item : in out Held_Process) return Boolean is
         Result : Hostkit.Spawn.Status;
      begin
         if not Hostkit.Spawn.Is_Valid (Item.Child) then
            return True;
         elsif Hostkit.Spawn.Supervision.Has_Ended (Item.Child, Result) then
            --  POSIX descendants share the leader's group; Windows descendants
            --  are in the Job Object that Release terminates.
            Stop_Group (Item.Child);
            Hostkit.Spawn.Release (Item.Child);
            return True;
         end if;

         Item.Ticks := Item.Ticks + 1;
         if Item.Ticks mod 20 = 0 then
            --  A refused stop may have been transient. Retry at one-second
            --  intervals without making the foreground teardown wait for it.
            Stop_Group (Item.Child);
            declare
               Stopped : constant Boolean := Hostkit.Spawn.Supervision.Stop_Now (Item.Child);
               pragma Unreferenced (Stopped);
            begin
               null;
            end;
         end if;
         return False;
      exception
         when others =>
            return False;
      end Collected;

      function Output_Removed (Item : in out Held_Process) return Boolean is
         Path : constant String := To_String (Item.Output);
      begin
         if Path = "" or else not Ada.Directories.Exists (Path) then
            return True;
         end if;
         Ada.Directories.Delete_File (Path);
         return True;
      exception
         when others =>
            --  TerminateJobObject is asynchronous. A descendant may still
            --  hold its inherited output handle for a short while after the
            --  leader was collected, so retain the path and try again. A
            --  permanent error is eventually let go rather than polled for
            --  the rest of the program's life.
            Item.Remove_Tries := Item.Remove_Tries + 1;
            return Item.Remove_Tries >= Most_Remove_Tries;
      end Output_Removed;

      procedure Poll is
      begin
         for Index in reverse 1 .. Natural (Held.Length) loop
            declare
               Item : Held_Process := Held (Index);
            begin
               if Collected (Item) and then Output_Removed (Item) then
                  Held.Delete (Index);
               else
                  Held.Replace_Element (Index, Item);
               end if;
            end;
         end loop;
      end Poll;
   begin
      loop
         if Held.Is_Empty then
            select
               accept Take
                 (Child  : in out Hostkit.Spawn.Process_Handle;
                  Output : String)
               do
                  if Hostkit.Spawn.Is_Valid (Child) or else Output /= "" then
                     Held.Append
                       (Held_Process'
                          (Child  => Child,
                           Output => To_Unbounded_String (Output),
                           Ticks  => 0,
                           Remove_Tries => 0));
                     Child := Hostkit.Spawn.Invalid_Process;
                  end if;
               end Take;
            or
               terminate;
            end select;
         else
            select
               accept Take
                 (Child  : in out Hostkit.Spawn.Process_Handle;
                  Output : String)
               do
                  if Hostkit.Spawn.Is_Valid (Child) or else Output /= "" then
                     Held.Append
                       (Held_Process'
                          (Child  => Child,
                           Output => To_Unbounded_String (Output),
                           Ticks  => 0,
                           Remove_Tries => 0));
                     Child := Hostkit.Spawn.Invalid_Process;
                  end if;
               end Take;
            or
               delay 0.05;
            end select;
         end if;
         Poll;
         exit when not Ada.Task_Identification.Is_Callable
           (Ada.Task_Identification.Environment_Task);
      end loop;
   end Reaper;

   procedure Adopt
     (Child  : in out Hostkit.Spawn.Process_Handle;
      Output : String := "")
   is
   begin
      Reaper.Take (Child, Output);
   end Adopt;

   procedure Remove_When_Free (Output : String) is
      Child : Hostkit.Spawn.Process_Handle := Hostkit.Spawn.Invalid_Process;
   begin
      if Output /= "" then
         Reaper.Take (Child, Output);
      end if;
   end Remove_When_Free;

end Model_Runner.CLI.Process_Reaper;
