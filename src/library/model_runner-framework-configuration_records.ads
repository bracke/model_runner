with Ada.Containers.Indefinite_Ordered_Maps;

with Model_Runner.Errors;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Stores;

--  The resolved configuration representation needed by task publication.
--  Kept separate from template composition and inference policy so clients
--  that only publish tasks do not link the operational configuration engine.
package Model_Runner.Framework.Configuration_Records is
   --  Names to values.
   package Value_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (Key_Type => String, Element_Type => String);

   --  Raised where the project's configuration exists but cannot be read.
   Configuration_Unavailable : exception;

   --  The fingerprint of what a configuration says, its own fingerprint
   --  and its provenance left out.
   --
   --  @param Value The configuration.
   --  @return The fingerprint.
   function Fingerprint (Value : Records.Item) return String;

   --  Read the project's resolved configuration, refusing one whose
   --  recorded fingerprint does not match what it says.
   --
   --  @param Item The project's store.
   --  @param Value The configuration read.
   --  @param Status Success, not found, or why it could not be read.
   procedure Read
     (Item : Stores.Store; Value : out Records.Item; Status : out Model_Runner.Errors.Error_Info);

   --  Whether a read failed other than by there being no configuration.
   --
   --  @param Status What Read said.
   --  @return Whether the configuration is there and cannot be read.
   function Unreadable (Status : Model_Runner.Errors.Error_Info) return Boolean;

   --  The project's configuration, or an empty one where there is none.
   --
   --  @param Item The project's store.
   --  @return The configuration.
   --  @exception Configuration_Unavailable Where it is there and cannot be
   --    read.
   function Required (Item : Stores.Store) return Records.Item;
end Model_Runner.Framework.Configuration_Records;
