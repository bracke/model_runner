with Ada.Characters.Handling;

with Model_Runner.Framework.Records;
with Model_Runner.Framework.Schemas;

package body Model_Runner.Framework.Results is

   use Ada.Strings.Unbounded;

   package E renames Model_Runner.Errors;

   ---------------
   -- Kind_Word --
   ---------------

   function Kind_Word (Kind : Result_Kind) return String
   is (Ada.Characters.Handling.To_Lower (Result_Kind'Image (Kind)));

   --  The kind a word names, if it names one.
   procedure Kind_Of
     (Word  : String;
      Kind  : out Result_Kind;
      Found : out Boolean) is
   begin
      for Candidate in Result_Kind loop
         if Kind_Word (Candidate) = Word then
            Kind := Candidate;
            Found := True;
            return;
         end if;
      end loop;
      Kind := Analysis;
      Found := False;
   end Kind_Of;

   --  A result's content as one text, each part preceded by its length so
   --  that no two different results run together into the same one.
   function Content (Value : Result) return String is
      function Part (Text : String) return String is
         Image : constant String := Natural'Image (Text'Length);
      begin
         return Image (Image'First + 1 .. Image'Last) & ":" & Text;
      end Part;
   begin
      return Part (Kind_Word (Value.Kind)) & Part (To_String (Value.Producer))
        & Part (To_String (Value.Summary)) & Part (To_String (Value.Payload))
        & Part (To_String (Value.Provenance))
        & Part (To_String (Value.References));
   end Content;

   -------------------
   -- Identifier_Of --
   -------------------

   function Identifier_Of (Value : Result) return String
   is ("RES-" & Ada.Characters.Handling.To_Upper
                  (Fingerprint (Content (Value))));

   --  The result a record holds.
   function From_Record (Item : Records.Item) return Result is
      Kind  : Result_Kind;
      Found : Boolean;
   begin
      Kind_Of (Records.Get (Item, "result_type"), Kind, Found);
      return
        (Id         => To_Unbounded_String (Records.Entity_Id (Item)),
         Kind       => Kind,
         Producer   => To_Unbounded_String (Records.Get (Item, "producer")),
         Created_At => To_Unbounded_String (Records.Get (Item, "created_at")),
         Summary    => To_Unbounded_String (Records.Get (Item, "summary")),
         Payload    => To_Unbounded_String (Records.Get (Item, "payload")),
         Provenance => To_Unbounded_String (Records.Get (Item, "provenance")),
         References => To_Unbounded_String (Records.Get (Item, "references")));
   end From_Record;

   ---------
   -- Add --
   ---------

   procedure Add
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Value  : in out Result;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Id : constant String := Identifier_Of (Value);
   begin
      Value.Id := To_Unbounded_String (Id);

      if Stores.Exists (Item, Results_Area, Id) then
         declare
            Held : Result;
         begin
            Read (Item, Id, Held, Status);
            if E.Is_Error (Status) then
               return;
            elsif Content (Held) /= Content (Value) then
               Status := E.Make (E.Framework_Result_Conflict);
               E.Add_Text (Status, "name", Id);
               return;
            end if;

            --  Stored already, and when it was stored is when it was made.
            Value.Created_At := Held.Created_At;
            return;
         end;
      end if;

      declare
         Stamp  : constant String := Timestamp;
         Stored : Records.Item :=
           Records.Create (Schemas.Result_Schema, 1, Id, 1);
      begin
         Value.Created_At := To_Unbounded_String (Stamp);
         Records.Set (Stored, "result_type", Kind_Word (Value.Kind));
         Records.Set (Stored, "producer", To_String (Value.Producer));
         Records.Set (Stored, "created_at", Stamp);
         Records.Set (Stored, "summary", To_String (Value.Summary));
         Records.Set (Stored, "payload", To_String (Value.Payload));
         Records.Set
           (Stored, "payload_fingerprint",
            Fingerprint (To_String (Value.Payload)));
         Records.Set (Stored, "provenance", To_String (Value.Provenance));
         Records.Set (Stored, "references", To_String (Value.References));
         Stores.Put (Change, Results_Area, Id, Stored);
      end;
      Status := E.Success;
   end Add;

   ----------
   -- Read --
   ----------

   procedure Read
     (Item   : Stores.Store;
      Id     : String;
      Value  : out Result;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Stored : Records.Item;
   begin
      Value := (others => <>);
      Stores.Read (Item, Results_Area, Id, Stored, Status);
      if E.Is_Error (Status) then
         return;
      end if;

      Value := From_Record (Stored);
      if Fingerprint (To_String (Value.Payload))
           /= Records.Get (Stored, "payload_fingerprint")
        or else Identifier_Of (Value) /= Id
      then
         Status := E.Make (E.Framework_Integrity_Failed);
         E.Add_Text (Status, "path", Directory_Name (Results_Area) & "/" & Id,
                     E.Param_Path);
      end if;
   end Read;

end Model_Runner.Framework.Results;
