with Ada.Calendar.Formatting;
with Ada.Calendar;
with Ada.Characters.Handling;
with Ada.Directories;
with Ada.Strings.Fixed;

with Model_Runner.Framework.Files;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Schemas;

package body Model_Runner.Framework.Results is

   use Ada.Strings.Unbounded;

   package E renames Model_Runner.Errors;

   function Trim (Text : String) return String
   is (Ada.Strings.Fixed.Trim (Text, Ada.Strings.Both));

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

   --  Where a payload kept apart is: beside the results, by its fingerprint.
   function Payload_Path (Item : Stores.Store; Print : String) return String
   is (Stores.Root (Item) & "/" & Directory_Name (Results_Area) & "/payloads/" & Print & ".txt");

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
            if E."=" (Status.Code, E.Framework_Integrity_Failed) then
               --  Its payload kept apart was cut short or changed, and this
               --  is the payload the record's fingerprint names: put it back
               --  whole.
               declare
                  Stored : Records.Item;
                  Got    : E.Error_Info;
               begin
                  Stores.Read (Item, Results_Area, Id, Stored, Got);
                  if E.Is_Ok (Got) and then Records.Get (Stored, "payload_file") /= ""
                    and then Records.Get (Stored, "payload_fingerprint")
                               = Fingerprint (To_String (Value.Payload))
                  then
                     Files.Write_Whole
                       (Payload_Path (Item, Records.Get (Stored, "payload_file")),
                        To_String (Value.Payload), Status);
                     if E.Is_Ok (Status) then
                        Read (Item, Id, Held, Status);
                     end if;
                  end if;
               end;
            end if;
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
         Records.Set
           (Stored, "payload_fingerprint",
            Fingerprint (To_String (Value.Payload)));
         Records.Set (Stored, "payload_size", Trim (Natural'Image (Length (Value.Payload))));
         if Length (Value.Payload) > Inline_Limit then
            --  Kept apart, named by what it is: the same payload twice is
            --  one file, and a result that is never committed leaves only
            --  a file its fingerprint names.
            declare
               Print : constant String := Fingerprint (To_String (Value.Payload));
               Path  : constant String := Payload_Path (Item, Print);
               Held  : Unbounded_String;
               Read  : E.Error_Info;
            begin
               --  Written whole or not at all, and written again where what
               --  is there is not what its name says -- a write a crash cut
               --  short.
               if Ada.Directories.Exists (Path) then
                  Files.Read_Text (Path, Held, Read);
               end if;
               if not Ada.Directories.Exists (Path) or else E.Is_Error (Read)
                 or else Fingerprint (To_String (Held)) /= Print
               then
                  if not Files.Make_Directory (Ada.Directories.Containing_Directory (Path)) then
                     Files.Write_Failed (Path, Status);
                     return;
                  end if;
                  Files.Write_Whole (Path, To_String (Value.Payload), Status);
                  if E.Is_Error (Status) then
                     return;
                  end if;
               end if;
               Records.Set (Stored, "payload_file", Print);
            end;
         else
            Records.Set (Stored, "payload", To_String (Value.Payload));
         end if;
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
     (Item         : Stores.Store;
      Id           : String;
      Value        : out Result;
      Status       : out Model_Runner.Errors.Error_Info;
      With_Payload : Boolean := True)
   is
      Stored : Records.Item;
      Apart  : Boolean;
   begin
      Value := (others => <>);
      Stores.Read (Item, Results_Area, Id, Stored, Status);
      if E.Is_Error (Status) then
         return;
      end if;

      Value := From_Record (Stored);
      Apart := Records.Get (Stored, "payload_file") /= "";
      if Apart and then not With_Payload then
         --  What it is, without the payload asked not to be read.
         return;
      elsif Apart then
         Files.Read_Text
           (Payload_Path (Item, Records.Get (Stored, "payload_file")), Value.Payload, Status);
         if E.Is_Error (Status) then
            Status := E.Make (E.Framework_Integrity_Failed);
            E.Add_Text (Status, "path", Directory_Name (Results_Area) & "/payloads/"
                        & Records.Get (Stored, "payload_file"), E.Param_Path);
            return;
         end if;
      end if;
      if Fingerprint (To_String (Value.Payload))
           /= Records.Get (Stored, "payload_fingerprint")
        or else Identifier_Of (Value) /= Id
      then
         Status := E.Make (E.Framework_Integrity_Failed);
         E.Add_Text (Status, "path", Directory_Name (Results_Area) & "/" & Id,
                     E.Param_Path);
      end if;
   end Read;

   ------------------
   -- Payload_Size --
   ------------------

   function Payload_Size (Item : Stores.Store; Id : String) return Natural is
      Stored : Records.Item;
      Status : E.Error_Info;
   begin
      Stores.Read (Item, Results_Area, Id, Stored, Status);
      if E.Is_Error (Status) then
         return 0;
      end if;
      declare
         Text : constant String := Records.Get (Stored, "payload_size");
      begin
         return (if Text'Length in 1 .. 9 and then (for all C of Text => C in '0' .. '9')
                 then Natural'Value (Text) else Records.Get (Stored, "payload")'Length);
      end;
   end Payload_Size;

   -----------
   -- Prune --
   -----------

   procedure Prune
     (Item         : Stores.Store;
      Change       : in out Stores.Transaction;
      Raw_Log_Days : Natural;
      Context_Days : Natural;
      Removed      : out Natural;
      Cache_Days   : Natural := 0)
   is
      --  The moment some days ago, written as a result's created_at is.
      function Before (Days : Natural) return String is
         use type Ada.Calendar.Time;
         Text : String :=
           Ada.Calendar.Formatting.Image (Ada.Calendar.Clock - Duration (Days) * 86_400.0);
      begin
         Text (Text'First + 10) := 'T';
         return Text & "Z";
      end Before;

      Raw_Cut     : constant String := (if Raw_Log_Days = 0 then "" else Before (Raw_Log_Days));
      Context_Cut : constant String := (if Context_Days = 0 then "" else Before (Context_Days));
      Cache_Cut   : constant String := (if Cache_Days = 0 then "" else Before (Cache_Days));
   begin
      Removed := 0;
      for Id of Stores.Names (Item, Results_Area) loop
         declare
            Stored : Records.Item;
            Status : E.Error_Info;
         begin
            Stores.Read (Item, Results_Area, Id, Stored, Status);
            if E.Is_Ok (Status) then
               declare
                  Kind    : constant String := Records.Get (Stored, "result_type");
                  Made_At : constant String := Records.Get (Stored, "created_at");
               begin
                  if (Raw_Cut /= "" and then Kind = Kind_Word (Verification)
                      and then Records.Get (Stored, "producer") = "execution"
                      and then Made_At < Raw_Cut)
                    or else (Context_Cut /= "" and then Kind = Kind_Word (Context_Report)
                             and then Made_At < Context_Cut)
                    or else (Cache_Cut /= "" and then Kind = Kind_Word (Impact_Report)
                             and then Made_At < Cache_Cut)
                  then
                     Stores.Remove (Change, Results_Area, Id);
                     Removed := Removed + 1;
                  end if;
               end;
            end if;
         end;
      end loop;
   end Prune;

   ----------------------
   -- Collect_Payloads --
   ----------------------

   procedure Collect_Payloads (Item : Stores.Store; Removed : out Natural) is
      Directory : constant String :=
        Stores.Root (Item) & "/" & Directory_Name (Results_Area) & "/payloads";
      Wanted    : Name_Lists.Vector;
   begin
      Removed := 0;
      if not Ada.Directories.Exists (Directory) then
         return;
      end if;
      for Id of Stores.Names (Item, Results_Area) loop
         declare
            Stored : Records.Item;
            Status : E.Error_Info;
         begin
            Stores.Read (Item, Results_Area, Id, Stored, Status);
            if E.Is_Ok (Status) and then Records.Get (Stored, "payload_file") /= "" then
               Wanted.Append (Records.Get (Stored, "payload_file") & ".txt");
            end if;
         end;
      end loop;
      for Name of Files.Files_In (Directory) loop
         if not Wanted.Contains (Name) then
            Files.Discard (Directory & "/" & Name);
            Removed := Removed + 1;
         end if;
      end loop;
   end Collect_Payloads;

end Model_Runner.Framework.Results;
