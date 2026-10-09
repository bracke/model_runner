with Ada.Characters.Handling;

with Model_Runner.Framework.Identifiers;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Schemas;

package body Model_Runner.Framework.Events is

   use Ada.Strings.Unbounded;

   package E renames Model_Runner.Errors;

   --  Nine digits, so the events' names sort as their numbers do.
   function Nine (Value : Natural) return String is
      Image : constant String := Natural'Image (Value);
      Plain : constant String := Image (Image'First + 1 .. Image'Last);
   begin
      return [1 .. Integer'Max (0, 9 - Plain'Length) => '0'] & Plain;
   end Nine;

   function Consumer_Name (Consumer : String) return String
   is ("consumed." & Consumer);

   ---------------
   -- Kind_Name --
   ---------------

   function Kind_Name (Kind : Event_Kind) return String is
      Result : String := Ada.Characters.Handling.To_Lower (Event_Kind'Image (Kind));
      Start  : Boolean := True;
   begin
      for Char of Result loop
         if Start then
            Char := Ada.Characters.Handling.To_Upper (Char);
         end if;
         Start := Char = '_';
      end loop;
      return Result;
   end Kind_Name;

   --------------
   -- Revision --
   --------------

   function Revision (Item : Stores.Store) return Natural is
   begin
      return Stores.Last_Number (Item, "EVT");
   end Revision;

   ------------------------
   -- Workspace_Revision --
   ------------------------

   function Workspace_Revision (Item : Stores.Store) return Natural is
   begin
      return Stores.Last_Number (Item, "SRC");
   end Workspace_Revision;

   ----------
   -- Emit --
   ----------

   procedure Emit
     (Item    : Stores.Store;
      Change  : in out Stores.Transaction;
      Kind    : Event_Kind;
      Subject : String;
      Detail  : String;
      Id      : out Ada.Strings.Unbounded.Unbounded_String;
      Status  : out Model_Runner.Errors.Error_Info)
   is
      Number      : Natural;
      Transaction : Unbounded_String;
   begin
      Id := Null_Unbounded_String;

      if not Identifiers.Is_Valid (Subject) then
         Status := E.Make (E.Framework_Identifier_Invalid);
         E.Add_Text (Status, "value", Subject);
         return;
      end if;

      Stores.Identify (Item, Change, Transaction, Status);
      if E.Is_Ok (Status) then
         Stores.Allocate_Number (Item, Change, "EVT", "", Number, Status);
      end if;
      --  A change of the source moves the workspace's revision too.
      if E.Is_Ok (Status) and then Kind = Source_Changed then
         declare
            Source_Number : Natural;
         begin
            Stores.Allocate_Number (Item, Change, "SRC", "", Source_Number, Status);
         end;
      end if;
      if E.Is_Error (Status) then
         return;
      end if;

      declare
         Event_Id : constant String := "EVT-" & Nine (Number);
         Value    : Records.Item :=
           Records.Create (Schemas.Event_Schema, 1, Event_Id, 1);
      begin
         Records.Set (Value, "event_kind", Kind_Name (Kind));
         Records.Set (Value, "sequence", Nine (Number));
         Records.Set (Value, "subject", Subject);
         Records.Set (Value, "transaction", To_String (Transaction));
         Records.Set (Value, "occurred_at", Timestamp);
         if Detail /= "" then
            Records.Set (Value, "detail", Detail);
         end if;
         Stores.Put (Change, Events_Area, "event-" & Nine (Number), Value);
         Id := To_Unbounded_String (Event_Id);
      end;
   end Emit;

   -----------
   -- Since --
   -----------

   function Since (Item : Stores.Store; After : Natural) return Event_List is
      Result : Event_List;
   begin
      for Name of Stores.Names (Item, Events_Area) loop
         declare
            Value  : Records.Item;
            Status : E.Error_Info;
            Number : Natural := 0;
         begin
            Stores.Read (Item, Events_Area, Name, Value, Status);
            if E.Is_Ok (Status) then
               for Char of Records.Get (Value, "sequence") loop
                  Number := Number * 10
                    + (Character'Pos (Char) - Character'Pos ('0'));
               end loop;
            end if;

            if E.Is_Ok (Status) and then Number > After then
               declare
                  Next : Event :=
                    (Id          => To_Unbounded_String
                                      (Records.Entity_Id (Value)),
                     Sequence    => Number,
                     Kind_Word   => To_Unbounded_String
                                      (Records.Get (Value, "event_kind")),
                     Subject     => To_Unbounded_String
                                      (Records.Get (Value, "subject")),
                     Transaction => To_Unbounded_String
                                      (Records.Get (Value, "transaction")),
                     Occurred_At => To_Unbounded_String
                                      (Records.Get (Value, "occurred_at")),
                     Detail      => To_Unbounded_String
                                      (Records.Get (Value, "detail")),
                     others      => <>);
               begin
                  for Kind in Event_Kind loop
                     if Kind_Name (Kind) = To_String (Next.Kind_Word) then
                        Next.Kind := Kind;
                        Next.Known := True;
                     end if;
                  end loop;
                  Result.Events.Append (Next);
               end;
            end if;
         end;
      end loop;
      return Result;
   end Since;

   function Length (From : Event_List) return Natural
   is (Natural (From.Events.Length));

   function Element (From : Event_List; Index : Positive) return Event
   is (From.Events (Index));

   -------------
   -- Consume --
   -------------

   procedure Consume
     (Item     : Stores.Store;
      Change   : in out Stores.Transaction;
      Consumer : String;
      Event_Id : String;
      Fresh    : out Boolean;
      Status   : out Model_Runner.Errors.Error_Info)
   is
      Name   : constant String := Consumer_Name (Consumer);
      Held   : Records.Item;
      Staged : Boolean;
   begin
      Fresh := False;
      Status := E.Success;

      if not Stores.Is_Name (Name) then
         Status := E.Make (E.Framework_Name_Invalid);
         E.Add_Text (Status, "value", Consumer);
         return;
      elsif not Identifiers.Is_Valid (Event_Id) then
         Status := E.Make (E.Framework_Identifier_Invalid);
         E.Add_Text (Status, "value", Event_Id);
         return;
      end if;

      --  What this transaction already says the consumer has done, else
      --  what the state says, else nothing yet.
      Stores.Pending (Change, Runtime_Area, Name, Held, Staged);
      if not Staged then
         if Stores.Exists (Item, Runtime_Area, Name) then
            Stores.Read (Item, Runtime_Area, Name, Held, Status);
            if E.Is_Error (Status) then
               return;
            end if;
            Records.Set_Revision (Held, Records.Revision (Held) + 1);
         else
            Held := Records.Create
              (Schemas.Consumption_Schema, 1, "CONSUMER", 1);
            Records.Set (Held, "consumer", Consumer);
         end if;
      end if;

      if Records.Has (Held, "done." & Event_Id) then
         return;
      end if;

      Records.Set (Held, "done." & Event_Id, Timestamp);
      Stores.Put (Change, Runtime_Area, Name, Held);
      Fresh := True;
   end Consume;

end Model_Runner.Framework.Events;
