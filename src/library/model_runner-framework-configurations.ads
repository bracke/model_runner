with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Strings.Unbounded;

with Model_Runner.Errors;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Stores;
with Model_Runner.Framework.Templates;

--  What a project is configured as, and how it came to be.
--
--  Initializing a project resolves a composed template against the project
--  directory and what the caller supplied: discovery rules look at the
--  files that are there, each input takes the value it was given, else the
--  one discovery found, else its default, and every declaration has the
--  inputs it names written into it. What comes out is the Resolved Project
--  Configuration -- one record, whose revision is the configuration's
--  revision and whose fingerprint covers what it means and nothing about
--  where or when it was made -- together with the facts the templates and
--  the discovery established, and the directories and files the templates
--  ask for. From then on the project runs on that record, not on the
--  template: removing or changing the template changes nothing.
--
--  Within a value, ${name} is the input called name, and ${directory_name}
--  is the name of the project's directory. A project's name is its
--  project_name input when a template asks for one, and its directory's
--  name otherwise.
package Model_Runner.Framework.Configurations is

   --  Names to values: the inputs given, found or resolved.
   package Value_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (Key_Type => String, Element_Type => String);

   --  What initializing a project will do.
   type Plan is record
      --  What the project will be called.
      Project_Name  : Ada.Strings.Unbounded.Unbounded_String;

      --  Every input's value, secrets included.
      Inputs        : Value_Maps.Map;

      --  The inputs that are required and have no value.
      Missing       : Name_Lists.Vector;

      --  Facts to record: the templates' and what discovery found.
      Template_Facts   : Value_Maps.Map;
      Discovered_Facts : Value_Maps.Map;

      --  Directories to make and files to write in the project, by path.
      Directories   : Name_Lists.Vector;
      Files         : Value_Maps.Map;

      --  The configuration, at revision 1.
      Configuration : Records.Item;
   end record;

   --  What initialization did in the project directory.
   type Outcome is record
      Made_Directories : Name_Lists.Vector;
      Written_Files    : Name_Lists.Vector;

      --  Files the templates declare that were there already and were left
      --  as they were.
      Kept_Files       : Name_Lists.Vector;
   end record;

   --  The fingerprint of a configuration: of what it configures, and not of
   --  which templates it came from, where they were read, its revision or
   --  the fingerprint itself.
   --
   --  @param Value The configuration record.
   --  @return Sixteen hexadecimal digits.
   function Configuration_Fingerprint (Value : Records.Item) return String;

   --  Work out what initializing a project from a composition will do.
   --
   --  @param Composed The composed template.
   --  @param Project_Directory The project.
   --  @param Given Inputs the caller supplied, by identifier.
   --  @param Result The plan; its Missing is filled in even when Status
   --    reports inputs missing, so that a caller can ask for them.
   --  @param Status Framework_Input_Missing naming every required input
   --    with no value, Framework_Input_Invalid when a value is not one the
   --    input takes or names no input, and Framework_Template_Invalid when
   --    a value names an input there is not or writes a secret into the
   --    configuration.
   procedure Prepare
     (Composed          : Templates.Composition;
      Project_Directory : String;
      Given             : Value_Maps.Map;
      Result            : out Plan;
      Status            : out Model_Runner.Errors.Error_Info);

   --  Whether a value is one an input takes.
   --
   --  @param Declared The input.
   --  @param Value The value.
   --  @param Status Framework_Input_Invalid saying why when it is not.
   procedure Check_Input
     (Declared : Templates.Input_Declaration;
      Value    : String;
      Status   : out Model_Runner.Errors.Error_Info);

   --  Initialize a project: make its state with the configuration, its
   --  first revision's copy and the facts, all in one transaction, and
   --  then make the directories and write the files the plan names that
   --  are not there.
   --
   --  @param Item The store, open afterwards when Status is a success.
   --  @param Project_Directory The project.
   --  @param Planned The plan.
   --  @param Done What was made and what was left.
   --  @param Status Framework_Already_Initialized when the project has
   --    state, and a write failure otherwise.
   procedure Initialize
     (Item              : in out Stores.Store;
      Project_Directory : String;
      Planned           : Plan;
      Done              : out Outcome;
      Status            : out Model_Runner.Errors.Error_Info);

   --  Read a project's current configuration.
   --
   --  @param Item The store.
   --  @param Value The configuration record.
   --  @param Status Framework_Not_Found when the project has none, and
   --    Framework_Integrity_Failed when it no longer matches its
   --    fingerprint.
   procedure Read
     (Item   : Stores.Store;
      Value  : out Records.Item;
      Status : out Model_Runner.Errors.Error_Info);

end Model_Runner.Framework.Configurations;
