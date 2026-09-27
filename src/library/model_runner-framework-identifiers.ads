with Model_Runner.Framework.Records;

--  The names entities are known by.
--
--  An identifier is upper-case words joined by hyphens -- REQ-PARSER-017,
--  DEC-IO-003, CONFIG -- and it names the entity for as long as the entity
--  exists, whatever revisions it goes through. Numbered identifiers are
--  handed out by the harness from a counter kept in the project state, one
--  counter for each namespace and key, so no two entities are ever given
--  the same one and no model has to remember which numbers are taken.
package Model_Runner.Framework.Identifiers is

   --  Schema of the record the counters are kept in.
   Counters_Schema : constant String := "project.counters";

   --  Entity the counters record is about.
   Counters_Entity : constant String := "COUNTERS";

   --  Whether a string is an identifier: one or more words of upper-case
   --  letters, digits and underscores joined by single hyphens, the first
   --  starting with a letter.
   --
   --  @param Text The candidate.
   --  @return True when Text is an identifier.
   function Is_Valid (Text : String) return Boolean;

   --  A numbered identifier, its number written with at least three
   --  digits.
   --
   --  @param Namespace The kind of entity, as REQ or TASK.
   --  @param Key What it belongs to, as PARSER; empty for none.
   --  @param Number Its number.
   --  @return The identifier, as REQ-PARSER-017.
   function Format
     (Namespace : String;
      Key       : String;
      Number    : Positive) return String;

   --  A record holding no counters.
   --
   --  @return The counters record at revision 1.
   function Empty_Counters return Records.Item;

   --  Hand out the next identifier of a namespace and key, and count it.
   --
   --  @param Counters The counters record, advanced by one for this
   --    namespace and key.
   --  @param Namespace The kind of entity.
   --  @param Key What it belongs to; empty for none.
   --  @return The identifier, or the empty string when the namespace and
   --    key do not make one.
   function Allocate
     (Counters  : in out Records.Item;
      Namespace : String;
      Key       : String) return String;

end Model_Runner.Framework.Identifiers;
