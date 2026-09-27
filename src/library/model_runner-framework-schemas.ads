with Model_Runner.Errors;
with Model_Runner.Framework.Records;

--  What a record of each kind must hold.
--
--  A schema names the fields a record keeps: which must be there, which
--  may be, and what each holds -- text, a number, an identifier, or one of
--  a fixed set of words. It also says what becomes of a field it does not
--  name. Most schemas keep such a field as it was, so that state written
--  by a later build is not stripped by an earlier one rewriting it; a few,
--  whose every field means something, refuse it. A field in an extension
--  namespace -- a name with a colon in it -- is always kept. Neither kind
--  of unknown field is ever acted on.
--
--  A record says which version of its schema it keeps to. One written to a
--  later version than this build knows is refused, rather than read as if
--  it meant what an earlier version would have meant by it.
package Model_Runner.Framework.Schemas is

   --  The state root's own record.
   Root_Schema : constant String := "framework.root";

   --  The project's identity.
   Identity_Schema : constant String := "project.identity";

   --  One fact about the project.
   Fact_Schema : constant String := "project.fact";

   --  One stored result.
   Result_Schema : constant String := "result.object";

   --  The derived index of every entity in the state.
   Index_Schema : constant String := "index.entities";

   --  A project's resolved configuration, current or of one revision.
   Configuration_Schema : constant String := "project.configuration";

   --  The list of changes a transaction is making.
   Manifest_Schema : constant String := "journal.manifest";

   --  The version of a schema this build writes and reads.
   --
   --  @param Schema_Id The schema.
   --  @return Its version, or zero when this build does not know it.
   function Current_Version (Schema_Id : String) return Natural;

   --  Check a record against its schema.
   --
   --  @param Value The record.
   --  @param Origin Where it came from, for the diagnostic.
   --  @param Status Framework_Format_Unsupported when the record is of a
   --    later schema version than this build knows,
   --    Framework_Schema_Violation when it breaks its schema or names a
   --    schema nobody defined, and a success otherwise.
   procedure Validate
     (Value  : Records.Item;
      Origin : String;
      Status : out Model_Runner.Errors.Error_Info);

end Model_Runner.Framework.Schemas;
