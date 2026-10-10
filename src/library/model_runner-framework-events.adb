with Ada.Characters.Handling;
with Ada.Strings.Fixed;

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

   --  The sequence an event's identifier carries: EVT-000000012 is 12;
   --  Natural'Last for one that carries none, so it is never taken as
   --  settled.
   function Sequence_Of (Event_Id : String) return Natural is
      Digits_At : constant Natural := Ada.Strings.Fixed.Index (Event_Id, "-");
   begin
      if Digits_At = 0 or else Digits_At = Event_Id'Last
        or else (for some C of Event_Id (Digits_At + 1 .. Event_Id'Last) => C not in '0' .. '9')
        or else Event_Id'Last - Digits_At > 9
      then
         return Natural'Last;
      end if;
      return Natural'Value (Event_Id (Digits_At + 1 .. Event_Id'Last));
   end Sequence_Of;

   --  The sequence a consumer's record says it settled through.
   function Through_Of (Held : Records.Item) return Natural is
      Said : constant String := Records.Get (Held, "done.through");
   begin
      if Said'Length in 1 .. 9 and then (for all C of Said => C in '0' .. '9') then
         return Natural'Value (Said);
      end if;
      return 0;
   end Through_Of;

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
         --  The sequence is in the name: one at or before After is not read.
         if After > 0 and then Name'Length = 15
           and then Name (Name'First .. Name'First + 5) = "event-"
           and then (for all C of Name (Name'First + 6 .. Name'Last) => C in '0' .. '9')
           and then Natural'Value (Name (Name'First + 6 .. Name'Last)) <= After
         then
            goto Next_Name;
         end if;
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
         <<Next_Name>>
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

      if Records.Has (Held, "done." & Event_Id)
        or else Sequence_Of (Event_Id) <= Through_Of (Held)
      then
         return;
      end if;

      Records.Set (Held, "done." & Event_Id, Timestamp);
      Stores.Put (Change, Runtime_Area, Name, Held);
      Fresh := True;
   end Consume;

-------------
   -- Settled --
   -------------

   function Settled (Item : Stores.Store; Consumer : String) return Natural is
      Name   : constant String := Consumer_Name (Consumer);
      Held   : Records.Item;
      Status : E.Error_Info;
   begin
      if not Stores.Is_Name (Name) or else not Stores.Exists (Item, Runtime_Area, Name) then
         return 0;
      end if;
      Stores.Read (Item, Runtime_Area, Name, Held, Status);
      return (if E.Is_Ok (Status) then Through_Of (Held) else 0);
   end Settled;

   ------------
   -- Settle --
   ------------

   procedure Settle
     (Item     : Stores.Store;
      Change   : in out Stores.Transaction;
      Consumer : String;
      Through  : Natural;
      Status   : out Model_Runner.Errors.Error_Info)
   is
      Name   : constant String := Consumer_Name (Consumer);
      Held   : Records.Item;
      Staged : Boolean;
   begin
      Status := E.Success;
      if not Stores.Is_Name (Name) then
         Status := E.Make (E.Framework_Name_Invalid);
         E.Add_Text (Status, "value", Consumer);
         return;
      end if;
      Stores.Pending (Change, Runtime_Area, Name, Held, Staged);
      if not Staged then
         if Stores.Exists (Item, Runtime_Area, Name) then
            Stores.Read (Item, Runtime_Area, Name, Held, Status);
            if E.Is_Error (Status) then
               return;
            end if;
            Records.Set_Revision (Held, Records.Revision (Held) + 1);
         else
            Held := Records.Create (Schemas.Consumption_Schema, 1, "CONSUMER", 1);
            Records.Set (Held, "consumer", Consumer);
         end if;
      end if;
      if Through <= Through_Of (Held) then
         return;
      end if;
      Records.Set (Held, "done.through", Nine (Through));
      Stores.Put (Change, Runtime_Area, Name, Held);
   end Settle;

end Model_Runner.Framework.Events;
