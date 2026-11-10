with Ada.Containers.Indefinite_Ordered_Maps;

with Model_Runner.Errors;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Stores;

--  The resolved configuration representation needed by task publication.
--  Kept separate from template composition and inference policy so clients
--  that only publish tasks do not link the operational configuration engine.
package Model_Runner.Framework.Configuration_Records is
   package Value_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (Key_Type => String, Element_Type => String);

   Configuration_Unavailable : exception;

   function Fingerprint (Value : Records.Item) return String;

   procedure Read
     (Item : Stores.Store; Value : out Records.Item; Status : out Model_Runner.Errors.Error_Info);

   function Unreadable (Status : Model_Runner.Errors.Error_Info) return Boolean;

   function Required (Item : Stores.Store) return Records.Item;
end Model_Runner.Framework.Configuration_Records;
