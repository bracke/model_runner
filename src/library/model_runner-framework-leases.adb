with Ada.Containers.Indefinite_Hashed_Sets;
with Ada.Strings.Fixed;
with Ada.Strings.Hash;

with Hostkit.Host;
with Hostkit.Process;

with Model_Runner.Framework.Records;
with Model_Runner.Framework.Schemas;

package body Model_Runner.Framework.Leases is

   package E renames Model_Runner.Errors;

   Prefix : constant String := "lease.";

   --  The leases this process's own running work holds, by resource and
   --  owner; asked from the work's task and its watchers alike.
   package Key_Sets is new Ada.Containers.Indefinite_Hashed_Sets
     (String, Ada.Strings.Hash, "=");

   protected Running_Here is
      procedure Add (Key : String);
      procedure Remove (Key : String);
      function Has (Key : String) return Boolean;
   private
      Keys : Key_Sets.Set;
   end Running_Here;

   protected body Running_Here is
      procedure Add (Key : String) is
      begin
         Keys.Include (Key);
      end Add;

      procedure Remove (Key : String) is
      begin
         Keys.Exclude (Key);
      end Remove;

      function Has (Key : String) return Boolean is (Keys.Contains (Key));
   end Running_Here;

   function Key_Of (Resource, Owner : String) return String is (Resource & ASCII.NUL & Owner);

   -------------
   -- Working --
   -------------

   procedure Working (Resource : String; Owner : String) is
   begin
      Running_Here.Add (Key_Of (Resource, Owner));
   end Working;

   ------------------
   -- Done_Working --
   ------------------

   procedure Done_Working (Resource : String; Owner : String) is
   begin
      Running_Here.Remove (Key_Of (Resource, Owner));
   end Done_Working;

   --  The lease on a resource, if there is one that can be read; and
   --  whether there is one that cannot. A lease that is there and will not
   --  read is held by someone this cannot name -- a newer build's, one
   --  damaged -- and is not free: taken over, it would hand a running task
   --  to whoever asked next, and recovery would end the work holding it.
   procedure Held_Lease
     (Item       : Stores.Store;
      Resource   : String;
      Value      : out Records.Item;
      Found      : out Boolean;
      Unreadable : out Boolean)
   is
      Status : E.Error_Info;
   begin
      Found := False;
      Unreadable := False;
      Value := Records.Create ("", 1, "", 0);
      if Stores.Exists (Item, Runtime_Area, Prefix & Resource) then
         Stores.Read (Item, Runtime_Area, Prefix & Resource, Value, Status);
         Found := E.Is_Ok (Status);
         Unreadable := not Found;
      end if;
   end Held_Lease;

   --  Who holds a lease that cannot be read: nobody this can name, and so
   --  nobody any owner is.
   Unknown_Holder : constant String := "(an unreadable lease)";

   procedure Refuse_Unreadable (Resource : String; Status : out Model_Runner.Errors.Error_Info) is
   begin
      Status := E.Make (E.Framework_Integrity_Failed);
      E.Add_Text (Status, "name", Prefix & Resource);
      E.Add_Text (Status, "detail", "the lease on it is there and cannot be read; "
                  & "/check says what it is, and it is put right or removed by hand");
   end Refuse_Unreadable;

   --  This process, as a lease names it.
   function Own_Process return String
   is (Ada.Strings.Fixed.Trim
         (Integer'Image (Hostkit.Host.Own_Process_Id), Ada.Strings.Both));

   --  Whether a lease still holds: it has not run out, and the process that
   --  took it -- where it was taken on this machine -- is not known to be
   --  gone. A session that died holding a task lets it go at once; where the
   --  host cannot say, the lease holds until it runs out.
   --  A process that took it on this machine and is known to be there
   --  still holds it, run out or not: the time is a bound on a process
   --  nobody can see, not on one that is plainly working.
   function Running (Value : Records.Item) return Boolean is
      Process : constant String := Records.Get (Value, "process");
      Here    : constant Boolean :=
        Process /= "" and then Records.Get (Value, "host") = Hostkit.Host.Node_Name;
      --  The process that took it, by its id and what tells it apart from
      --  a later one given the id: a lease is held by the one there still,
      --  not by whatever program has its id now.
      Standing : constant Process_Standing :=
        (if Here then Standing_Of (Process & " " & Records.Get (Value, "process_identity")) else Not_Known);
      Alive   : constant Boolean :=
        Here and then Process /= Own_Process and then Standing = Same_Process;
   begin
      if Alive then
         return True;
      --  This process, and its own work still running under the lease:
      --  held, run out or not.
      elsif Here and then Process = Own_Process
        and then Running_Here.Has (Key_Of (Records.Get (Value, "resource"), Records.Get (Value, "owner")))
      then
         return True;
      elsif Records.Get (Value, "expires_at") <= Timestamp then
         return False;
      elsif not Here or else Process = Own_Process then
         return True;
      end if;
      return Standing /= Other_Process;
   end Running;

   procedure Refuse
     (Resource : String;
      Value    : Records.Item;
      Status   : out E.Error_Info) is
   begin
      Status := E.Make (E.Framework_Lease_Held);
      E.Add_Text (Status, "name", Resource);
      E.Add_Text (Status, "detail", Records.Get (Value, "owner"));
      E.Add_Text (Status, "value", Records.Get (Value, "expires_at"));
   end Refuse;

   -------------
   -- Acquire --
   -------------

   procedure Acquire
     (Item     : Stores.Store;
      Change   : in out Stores.Transaction;
      Resource : String;
      Owner    : String;
      Seconds  : Positive;
      Status   : out Model_Runner.Errors.Error_Info)
   is
      Held       : Records.Item;
      Found      : Boolean;
      Unreadable : Boolean;
   begin
      Status := E.Success;
      if not Stores.Is_Name (Prefix & Resource) then
         Status := E.Make (E.Framework_Name_Invalid);
         E.Add_Text (Status, "value", Resource);
         return;
      end if;

      Held_Lease (Item, Resource, Held, Found, Unreadable);
      if Unreadable then
         Refuse_Unreadable (Resource, Status);
         return;
      elsif Found and then Running (Held)
        and then Records.Get (Held, "owner") /= Owner
      then
         Refuse (Resource, Held, Status);
         return;
      end if;

      declare
         --  Renewed, the lease it was, so what this does not set is kept.
         Next : Records.Item :=
           Records.Create
             (Schemas.Lease_Schema, 1, "LEASE",
              (if Found then Records.Revision (Held) + 1 else 1));
      begin
         if Found then
            for Index in 1 .. Records.Field_Count (Held) loop
               Records.Set (Next, Records.Field_Name (Held, Index),
                            Records.Get (Held, Records.Field_Name (Held, Index)));
            end loop;
         end if;
         Records.Set (Next, "resource", Resource);
         Records.Set (Next, "owner", Owner);
         Records.Set
           (Next, "acquired_at",
            (if Found and then Running (Held)
             then Records.Get (Held, "acquired_at") else Timestamp));
         Records.Set (Next, "expires_at", Timestamp_After (Seconds));
         Records.Set (Next, "process", Own_Process);
         Records.Set (Next, "process_identity", Hostkit.Process.Identity_Of (Hostkit.Host.Own_Process_Id));
         Records.Set (Next, "host", Hostkit.Host.Node_Name);
         Stores.Put (Change, Runtime_Area, Prefix & Resource, Next);
      end;
   end Acquire;

   -------------
   -- Release --
   -------------

   procedure Release
     (Item     : Stores.Store;
      Change   : in out Stores.Transaction;
      Resource : String;
      Owner    : String;
      Status   : out Model_Runner.Errors.Error_Info)
   is
      Held       : Records.Item;
      Found      : Boolean;
      Unreadable : Boolean;
   begin
      Status := E.Success;
      Held_Lease (Item, Resource, Held, Found, Unreadable);
      if Unreadable then
         Refuse_Unreadable (Resource, Status);
         return;
      elsif not Found then
         return;
      elsif Running (Held) and then Records.Get (Held, "owner") /= Owner then
         Refuse (Resource, Held, Status);
         return;
      end if;
      Stores.Remove (Change, Runtime_Area, Prefix & Resource);
   end Release;

   --------------
   -- Owner_Of --
   --------------

   function Owner_Of (Item : Stores.Store; Resource : String) return String is
      Held       : Records.Item;
      Found      : Boolean;
      Unreadable : Boolean;
   begin
      Held_Lease (Item, Resource, Held, Found, Unreadable);
      return (if Found then Records.Get (Held, "owner") else "");
   end Owner_Of;

   ------------
   -- Holder --
   ------------

   function Holder (Item : Stores.Store; Resource : String) return String is
      Held       : Records.Item;
      Found      : Boolean;
      Unreadable : Boolean;
   begin
      Held_Lease (Item, Resource, Held, Found, Unreadable);
      return
        (if Unreadable then Unknown_Holder
         elsif Found and then Running (Held) then Records.Get (Held, "owner")
         else "");
   end Holder;

   -----------
   -- Stale --
   -----------

   function Stale (Item : Stores.Store) return Name_Lists.Vector is
      Result : Name_Lists.Vector;
   begin
      for Name of Stores.Names (Item, Runtime_Area) loop
         if Name'Length > Prefix'Length
           and then Name (Name'First .. Name'First + Prefix'Length - 1) = Prefix
         then
            declare
               Resource : constant String :=
                 Name (Name'First + Prefix'Length .. Name'Last);
               Held       : Records.Item;
               Found      : Boolean;
               Unreadable : Boolean;
            begin
               Held_Lease (Item, Resource, Held, Found, Unreadable);
               if Found and then not Running (Held) then
                  Result.Append (Resource);
               end if;
            end;
         end if;
      end loop;
      return Result;
   end Stale;

   -----------------
   -- Clear_Stale --
   -----------------

   procedure Clear_Stale
     (Item    : Stores.Store;
      Change  : in out Stores.Transaction;
      Cleared : out Name_Lists.Vector) is
   begin
      Cleared := Stale (Item);
      for Resource of Cleared loop
         Stores.Remove (Change, Runtime_Area, Prefix & Resource);
      end loop;
   end Clear_Stale;

end Model_Runner.Framework.Leases;
