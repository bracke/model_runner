with Model_Runner.Framework.Records;
with Model_Runner.Framework.Schemas;

package body Model_Runner.Framework.Leases is

   package E renames Model_Runner.Errors;

   Prefix : constant String := "lease.";

   --  The lease on a resource, if there is one that can be read.
   procedure Held_Lease
     (Item     : Stores.Store;
      Resource : String;
      Value    : out Records.Item;
      Found    : out Boolean)
   is
      Status : E.Error_Info;
   begin
      Found := False;
      Value := Records.Create ("", 1, "", 0);
      if Stores.Exists (Item, Runtime_Area, Prefix & Resource) then
         Stores.Read (Item, Runtime_Area, Prefix & Resource, Value, Status);
         Found := E.Is_Ok (Status);
      end if;
   end Held_Lease;

   function Running (Value : Records.Item) return Boolean
   is (Records.Get (Value, "expires_at") > Timestamp);

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
      Held  : Records.Item;
      Found : Boolean;
   begin
      Status := E.Success;
      if not Stores.Is_Name (Prefix & Resource) then
         Status := E.Make (E.Framework_Name_Invalid);
         E.Add_Text (Status, "value", Resource);
         return;
      end if;

      Held_Lease (Item, Resource, Held, Found);
      if Found and then Running (Held)
        and then Records.Get (Held, "owner") /= Owner
      then
         Refuse (Resource, Held, Status);
         return;
      end if;

      declare
         Next : Records.Item :=
           Records.Create
             (Schemas.Lease_Schema, 1, "LEASE",
              (if Found then Records.Revision (Held) + 1 else 1));
      begin
         Records.Set (Next, "resource", Resource);
         Records.Set (Next, "owner", Owner);
         Records.Set
           (Next, "acquired_at",
            (if Found and then Running (Held)
             then Records.Get (Held, "acquired_at") else Timestamp));
         Records.Set (Next, "expires_at", Timestamp_After (Seconds));
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
      Held  : Records.Item;
      Found : Boolean;
   begin
      Status := E.Success;
      Held_Lease (Item, Resource, Held, Found);
      if not Found then
         return;
      elsif Running (Held) and then Records.Get (Held, "owner") /= Owner then
         Refuse (Resource, Held, Status);
         return;
      end if;
      Stores.Remove (Change, Runtime_Area, Prefix & Resource);
   end Release;

   ------------
   -- Holder --
   ------------

   function Holder (Item : Stores.Store; Resource : String) return String is
      Held  : Records.Item;
      Found : Boolean;
   begin
      Held_Lease (Item, Resource, Held, Found);
      return
        (if Found and then Running (Held) then Records.Get (Held, "owner")
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
               Held     : Records.Item;
               Found    : Boolean;
            begin
               Held_Lease (Item, Resource, Held, Found);
               if Found and then not Running (Held) then
                  Result.Append (Resource);
               end if;
            end;
         end if;
      end loop;
      return Result;
   end Stale;

end Model_Runner.Framework.Leases;
