with Model_Runner.Framework.Stores;

--  What the project has learned and worked out, for a person to read.
--
--  Two pages below the state directory, views/observations.md and
--  views/derivations.md, made from the observations and the derivations
--  kept and made again whenever the project changes. They are projections
--  and nothing more: each says at its top that it is generated and not to
--  be edited, nothing reads them, an edit to one changes nothing and is
--  gone the next time it is made, and a project without them -- deleted,
--  never made, or turned off with the scalar views.markdown = off -- works
--  the same. Made from the same state, a page is the same bytes: it holds
--  no time but the records' own, and is written only when it differs.
package Model_Runner.Framework.Views is

   --  The folder below the state directory the pages are in.
   Directory : constant String := "views";

   --  What each page says first.
   Generated_Mark : constant String :=
     "GENERATED " & Character'Val (16#E2#) & Character'Val (16#80#) & Character'Val (16#94#)
     & " DO NOT EDIT";

   --  The observations page: every observation, the active ones first, each
   --  with what it says, whether it applies now, and where it came from.
   --
   --  @param Item The store.
   --  @return The page.
   function Observations_Page (Item : Stores.Store) return String;

   --  The derivations page: every derivation kept, its kind, subject,
   --  algorithm, answer, and whether it is the latest of its kind.
   --
   --  @param Item The store.
   --  @return The page.
   function Derivations_Page (Item : Stores.Store) return String;

   --  Make the pages again where they differ from what the state makes now,
   --  or remove them where the project turned them off. A page that cannot
   --  be written is left as it was: nothing depends on one.
   --
   --  @param Item The store; nothing is written where it is open to read.
   procedure Refresh (Item : Stores.Store);

end Model_Runner.Framework.Views;
