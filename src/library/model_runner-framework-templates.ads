private with Ada.Containers.Vectors;

with Ada.Strings.Unbounded;

with Model_Runner.Errors;

--  Project templates: what a kind of project starts with, declared in a file.
--
--  The harness knows no kinds of project. Every kind it offers is a template
--  file installed beside it or in the user's configuration directory, and
--  what initializing a project does -- the questions asked, the facts
--  recorded, the directories made, the configuration written -- is what the
--  templates it composes declare. A template is read once, at
--  initialization; the project keeps what it resolved to and where it came
--  from, and is no longer tied to the file.
--
--  A template is lines of text. Blank lines and lines starting with # are
--  passed over, and a value may carry \n, \t and \\ for a line break, a tab
--  and a backslash:
--
--     template = ada-cli
--     name = Ada CLI Application
--     description = A command-line program in Ada.
--     version = 1
--     includes = ada, alire, aunit
--
--     input project_name
--       type = identifier
--       label = Project name
--       required = true
--       default = ${directory_name}
--
--     discover alire.toml fact build_system = Alire
--     fact language = Ada_2022
--     directory src
--     file src/${project_name}.adb = procedure ...
--     scalar build.command = alr build
--     override scalar build.command = alr build --release
--
--  Declarations say how they compose. A scalar, a map entry, an adapter, a
--  verification profile, a task kind, a schema, a file and a fact each have
--  one value per key: two templates giving one key different values
--  conflict, unless the later one says override. A set is the union of what
--  every template puts in it; a list is what each adds, in composition order,
--  with a value given twice kept where it was first. Includes are composed
--  before the template that names them, left to right, each once.
package Model_Runner.Framework.Templates is

   --  How a declaration composes.
   type Setting_Kind is
     (Scalar_Setting,
      Map_Setting,
      Set_Setting,
      List_Setting,
      Adapter_Setting,
      Profile_Setting,
      Task_Kind_Setting,
      Schema_Setting,
      File_Setting,
      Fact_Setting,

      --  A statement of the project's or its language's baseline, which
      --  governs a subject nothing higher speaks to: baseline
      --  project.SUBJECT or baseline language.SUBJECT.
      Baseline_Setting);

   --  What an input holds, which is how it is checked.
   type Input_Kind is
     (Text_Input,
      Identifier_Input,
      Natural_Input,
      Path_Input,
      Choice_Input,
      Boolean_Input);

   --  One input a template asks for.
   type Input_Declaration is record
      Id          : Ada.Strings.Unbounded.Unbounded_String;
      Kind        : Input_Kind := Text_Input;
      Label       : Ada.Strings.Unbounded.Unbounded_String;
      Description : Ada.Strings.Unbounded.Unbounded_String;
      Required    : Boolean := False;
      Default     : Ada.Strings.Unbounded.Unbounded_String;

      --  The values a choice may take, separated by commas.
      Choices     : Ada.Strings.Unbounded.Unbounded_String;

      --  A secret is never written to the project state.
      Secret      : Boolean := False;

      --  Whether the value is kept in the resolved configuration.
      Persist     : Boolean := True;

      --  Rules a value is held to beyond its type, none where unset: the
      --  smallest and largest a natural may be, how long a value may be,
      --  and a pattern it must match, * standing for any run of
      --  characters and ? for any one.
      Minimum     : Natural := 0;
      Maximum     : Natural := Natural'Last;
      Max_Length  : Natural := Natural'Last;
      Pattern     : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  One composed declaration.
   type Setting is record
      Kind     : Setting_Kind := Scalar_Setting;
      Key      : Ada.Strings.Unbounded.Unbounded_String;
      Value    : Ada.Strings.Unbounded.Unbounded_String;
      Override : Boolean := False;

      --  The template that declared it.
      From     : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  A rule that finds something out from the project's files: when Path
   --  exists under the project, the fact or the input named by Key takes
   --  Value.
   type Discovery_Rule is record
      Path     : Ada.Strings.Unbounded.Unbounded_String;
      To_Input : Boolean := False;
      Key      : Ada.Strings.Unbounded.Unbounded_String;
      Value    : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  One template, as its file says.
   type Template is private;

   --  Templates found installed.
   type Registry is private;

   --  A template with everything it includes composed into it.
   type Composition is private;

   --  The word a declaration kind is written as.
   --
   --  @param Kind The kind.
   --  @return Its word, as task_kind.
   function Kind_Word (Kind : Setting_Kind) return String;

   --  Whether a path stays inside the project: relative, of letters,
   --  digits and _ . - /, and never stepping up out of where it starts.
   --
   --  @param Text The path.
   --  @return True when it does.
   function Is_Project_Path (Text : String) return Boolean;

   --  Read a template.
   --
   --  @param Text The file's text.
   --  @param Origin Where it came from.
   --  @param Value The template, when Status is a success.
   --  @param Status Framework_Template_Invalid, naming the line, when the
   --    text is not a template.
   procedure Parse
     (Text   : String;
      Origin : String;
      Value  : out Template;
      Status : out Model_Runner.Errors.Error_Info);

   --  A template's identifier, as ada-cli.
   --
   --  @param Value The template.
   --  @return Its identifier.
   function Id (Value : Template) return String;

   --  What a template is shown as.
   --
   --  @param Value The template.
   --  @return Its display name.
   function Display_Name (Value : Template) return String;

   --  What a template is for.
   --
   --  @param Value The template.
   --  @return Its description.
   function Description (Value : Template) return String;

   --  A template's version, as its file gives it.
   --
   --  @param Value The template.
   --  @return Its version.
   function Version (Value : Template) return String;

   --  A template's category, language and tags, joined for a listing.
   --
   --  @param Value The template.
   --  @return What it says about itself besides its name, or the empty
   --    string.
   function Details (Value : Template) return String;

   --  Where a template was read from.
   --
   --  @param Value The template.
   --  @return Its file.
   function Origin (Value : Template) return String;

   --  The fingerprint of a template's text.
   --
   --  @param Value The template.
   --  @return Sixteen hexadecimal digits.
   function Template_Fingerprint (Value : Template) return String;

   --  Read every template in some directories. A template whose identifier
   --  an earlier directory already gave is passed over, so the first
   --  directory named takes precedence. A file that cannot be read as a
   --  template is kept, as unavailable, under its file name.
   --
   --  @param Directories Where to look, in order of precedence; files
   --    ending .template are read.
   --  @param Into The templates found, sorted by identifier.
   procedure Discover
     (Directories : Name_Lists.Vector;
      Into        : out Registry);

   --  Add one template to a registry, unless it has one by that identifier.
   --
   --  @param Into The registry.
   --  @param Value The template.
   procedure Add (Into : in out Registry; Value : Template);

   --  How many templates a registry has.
   --
   --  @param From The registry.
   --  @return The count.
   function Count (From : Registry) return Natural;

   --  One template of a registry.
   --
   --  @param From The registry.
   --  @param Index 1 .. Count.
   --  @return The template.
   function Template_At (From : Registry; Index : Positive) return Template;

   --  Why a template cannot be used: it could not be read, or it does not
   --  compose.
   --
   --  @param From The registry.
   --  @param Index 1 .. Count.
   --  @return A success when it can be used.
   function Problem
     (From  : Registry;
      Index : Positive) return Model_Runner.Errors.Error_Info;

   --  Compose a template with everything it includes.
   --
   --  @param From The registry.
   --  @param Id The template.
   --  @param Result The composition, when Status is a success.
   --  @param Status Framework_Template_Not_Found when there is no such
   --    template or it includes one there is not, Framework_Template_Invalid
   --    when it cannot be read or includes itself, and
   --    Framework_Template_Conflict when two templates disagree.
   procedure Compose
     (From   : Registry;
      Id     : String;
      Result : out Composition;
      Status : out Model_Runner.Errors.Error_Info);

   --  The template a composition was made from.
   --
   --  @param Value The composition.
   --  @return The template.
   function Root (Value : Composition) return Template;

   --  The templates composed, in the order they were.
   --
   --  @param Value The composition.
   --  @return Their identifiers.
   function Order (Value : Composition) return Name_Lists.Vector;

   --  The fingerprint of everything composed: each template's, in order.
   --
   --  @param Value The composition.
   --  @return Sixteen hexadecimal digits.
   function Composition_Fingerprint (Value : Composition) return String;

   --  How many inputs a composition asks for.
   --
   --  @param Value The composition.
   --  @return The count.
   function Input_Count (Value : Composition) return Natural;

   --  One input a composition asks for, in declaration order.
   --
   --  @param Value The composition.
   --  @param Index 1 .. Input_Count.
   --  @return Its declaration.
   function Input_At
     (Value : Composition;
      Index : Positive) return Input_Declaration;

   --  How many declarations a composition resolved to.
   --
   --  @param Value The composition.
   --  @return The count.
   function Setting_Count (Value : Composition) return Natural;

   --  One declaration, sorted by kind and key; the values of a set are in
   --  order, and those of a list in composition order.
   --
   --  @param Value The composition.
   --  @param Index 1 .. Setting_Count.
   --  @return The declaration.
   function Setting_At
     (Value : Composition;
      Index : Positive) return Setting;

   --  How many discovery rules a composition has.
   --
   --  @param Value The composition.
   --  @return The count.
   function Rule_Count (Value : Composition) return Natural;

   --  One discovery rule, in composition order.
   --
   --  @param Value The composition.
   --  @param Index 1 .. Rule_Count.
   --  @return The rule.
   function Rule_At
     (Value : Composition;
      Index : Positive) return Discovery_Rule;

private

   use Ada.Strings.Unbounded;

   package Setting_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Setting);

   package Input_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Input_Declaration);

   package Rule_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Discovery_Rule);

   type Template is record
      Id          : Unbounded_String;
      Name        : Unbounded_String;
      Description : Unbounded_String;
      Version     : Unbounded_String;
      Category    : Unbounded_String;
      Language    : Unbounded_String;
      Tags        : Unbounded_String;
      Origin      : Unbounded_String;
      Fingerprint : Unbounded_String;
      Includes    : Name_Lists.Vector;
      Settings    : Setting_Vectors.Vector;
      Inputs      : Input_Vectors.Vector;
      Rules       : Rule_Vectors.Vector;

      --  Why the file could not be read as a template, when it could not.
      Broken      : Model_Runner.Errors.Error_Info;
   end record;

   package Template_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Template);

   type Registry is record
      Templates : Template_Vectors.Vector;
   end record;

   type Composition is record
      Root        : Template;
      Order       : Name_Lists.Vector;
      Fingerprint : Unbounded_String;
      Settings    : Setting_Vectors.Vector;
      Inputs      : Input_Vectors.Vector;
      Rules       : Rule_Vectors.Vector;
   end record;

end Model_Runner.Framework.Templates;
