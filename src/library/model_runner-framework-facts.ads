with Ada.Strings.Unbounded;

with Model_Runner.Errors;
with Model_Runner.Framework.Stores;

--  What is known about the project, and how it came to be known.
--
--  A fact is a key and a value -- language = Ada_2022, build_system =
--  Alire -- together with where it came from and how sure that source is.
--  Somebody saying so is authoritative; a guess from a file name is not,
--  and whatever later decides how much to check can tell the two apart.
--  Each fact is its own record in the project area, and changing one is a
--  new revision of it like any other change.
package Model_Runner.Framework.Facts is

   --  Where a fact came from.
   type Derivation_Source is
     (Explicit,
      Template,
      Semantic_Analysis,
      Build_Metadata,
      Naming_Convention,
      Heuristic);

   --  How sure its source is.
   type Confidence_Level is
     (Authoritative,
      Certain,
      Probable,
      Uncertain);

   --  One fact.
   type Fact is record
      Key        : Ada.Strings.Unbounded.Unbounded_String;
      Value      : Ada.Strings.Unbounded.Unbounded_String;
      Source     : Derivation_Source := Explicit;
      Confidence : Confidence_Level := Authoritative;

      --  Where it was found, where that is one place: a document's path.
      Origin     : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  Whether a string can be a fact's key: lower-case letters, digits and
   --  underscores, starting with a letter.
   --
   --  @param Key The candidate.
   --  @return True when it can.
   function Is_Key (Key : String) return Boolean;

   --  Stage a fact, as a new revision of the one it replaces.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Value The fact.
   --  @param Status Framework_Name_Invalid when its key is not one.
   procedure Record_Fact
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Value  : Fact;
      Status : out Model_Runner.Errors.Error_Info);

   --  Take a fact out of the registry: nobody says it any longer.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Key Its key; nothing is done when there is no such fact.
   procedure Retire
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Key    : String);

   --  Read a fact.
   --
   --  @param Item The store.
   --  @param Key Its key.
   --  @param Value The fact, when Status is a success.
   --  @param Status Framework_Not_Found when there is none.
   procedure Find
     (Item   : Stores.Store;
      Key    : String;
      Value  : out Fact;
      Status : out Model_Runner.Errors.Error_Info);

   --  The keys of every fact.
   --
   --  @param Item The store.
   --  @return Their keys, sorted.
   function Keys (Item : Stores.Store) return Name_Lists.Vector;

end Model_Runner.Framework.Facts;
