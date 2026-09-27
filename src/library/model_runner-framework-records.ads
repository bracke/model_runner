private with Ada.Containers.Vectors;
private with Ada.Strings.Unbounded;

with Model_Runner.Errors;

--  The one format every file of project state is written in.
--
--  A record is a set of named fields, each holding bytes. Four of them say
--  what the record is and are on every record: schema_id and
--  schema_version name the schema it keeps to, entity_id the entity it is
--  about, and revision which accepted change of that entity it holds.
--  Every other field is the schema's business, or -- for a field the
--  schema does not name -- nobody's: it is kept as it was read and written
--  back as it was, and nothing acts on it.
--
--  The text is canonical. The four header fields come first in that order,
--  the rest follow sorted by name, and each is written as its name, its
--  length in bytes and then exactly that many bytes:
--
--     model_runner-record 1
--     schema_id 16
--     project.identity
--     ...
--
--  so a value may hold anything, a line break included, and two records
--  holding the same fields are the same text whatever order the fields
--  were set in. That is what lets a record be fingerprinted.
package Model_Runner.Framework.Records is

   --  One record.
   type Item is private;

   --  The first line of every record.
   Signature : constant String := "model_runner-record 1";

   --  The longest record read, in bytes.
   Max_Bytes : constant := 64 * 1024 * 1024;

   --  Whether a string is a field name: letters, digits and the
   --  characters _ . : -, starting with a letter. A colon marks an
   --  extension namespace, as in vendor:field.
   --
   --  @param Name The candidate.
   --  @return True when Name can name a field.
   function Is_Field_Name (Name : String) return Boolean;

   --  A record with its header and no other field.
   --
   --  @param Schema_Id The schema it keeps to.
   --  @param Schema_Version That schema's version.
   --  @param Entity_Id The entity it is about.
   --  @param Revision Which accepted change of the entity it holds.
   --  @return The record.
   function Create
     (Schema_Id      : String;
      Schema_Version : Positive;
      Entity_Id      : String;
      Revision       : Natural) return Item;

   --  The schema a record keeps to.
   --
   --  @param Value The record.
   --  @return Its schema_id.
   function Schema_Id (Value : Item) return String;

   --  The version of that schema.
   --
   --  @param Value The record.
   --  @return Its schema_version.
   function Schema_Version (Value : Item) return Positive;

   --  The entity a record is about.
   --
   --  @param Value The record.
   --  @return Its entity_id.
   function Entity_Id (Value : Item) return String;

   --  Which accepted change of the entity a record holds.
   --
   --  @param Value The record.
   --  @return Its revision.
   function Revision (Value : Item) return Natural;

   --  Change a record's revision.
   --
   --  @param Value The record.
   --  @param To The new revision.
   procedure Set_Revision (Value : in out Item; To : Natural);

   --  Set a field, adding it when it is not there. A header field is set
   --  through its own operation.
   --
   --  @param Value The record.
   --  @param Name A field name; one that is not a field name, or is a
   --    header field's, is ignored.
   --  @param Text The field's bytes.
   procedure Set (Value : in out Item; Name : String; Text : String);

   --  Remove a field when it is there.
   --
   --  @param Value The record.
   --  @param Name The field.
   procedure Remove (Value : in out Item; Name : String);

   --  Whether a record has a field.
   --
   --  @param Value The record.
   --  @param Name The field.
   --  @return True when the field is there, header fields included.
   function Has (Value : Item; Name : String) return Boolean;

   --  A field's bytes.
   --
   --  @param Value The record.
   --  @param Name The field.
   --  @return Its bytes, or the empty string when it is not there.
   function Get (Value : Item; Name : String) return String;

   --  How many fields a record has besides its header.
   --
   --  @param Value The record.
   --  @return The count.
   function Field_Count (Value : Item) return Natural;

   --  The name of one of those fields, in canonical order.
   --
   --  @param Value The record.
   --  @param Index 1 .. Field_Count.
   --  @return Its name.
   function Field_Name (Value : Item; Index : Positive) return String;

   --  A record as canonical text.
   --
   --  @param Value The record.
   --  @return The text, which Parse reads back to an equal record.
   function Serialize (Value : Item) return String;

   --  The fingerprint of a record's canonical text.
   --
   --  @param Value The record.
   --  @return Sixteen hexadecimal digits.
   function Fingerprint_Of (Value : Item) return String;

   --  Read a record from its text.
   --
   --  Fields may come in any order; the record read is the same. A field
   --  given twice, a length that runs past the end, a header field missing
   --  or not a number where it must be one, and anything after the last
   --  field are all refused.
   --
   --  @param Text The text.
   --  @param Origin Where it came from, for the diagnostic.
   --  @param Value The record, when Status is a success.
   --  @param Status Framework_Record_Malformed when the text is not a
   --    record.
   procedure Parse
     (Text   : String;
      Origin : String;
      Value  : out Item;
      Status : out Model_Runner.Errors.Error_Info);

private

   use Ada.Strings.Unbounded;

   type Field is record
      Name  : Unbounded_String;
      Value : Unbounded_String;
   end record;

   package Field_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Field);

   --  Fields besides the header are kept sorted by name, which is what
   --  makes the text canonical without sorting at every write, and makes
   --  two records equal exactly when their text is.
   type Item is record
      Schema_Id      : Unbounded_String;
      Schema_Version : Positive := 1;
      Entity_Id      : Unbounded_String;
      Revision       : Natural := 0;
      Fields         : Field_Vectors.Vector;
   end record;

end Model_Runner.Framework.Records;
