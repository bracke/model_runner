with Ada.Containers.Indefinite_Vectors;
with Ada.Strings.Unbounded;

--  A tool's definition as a structure, written out as the JSON a model is
--  offered in one place.
--
--  A definition put together as JSON text by hand is a string the compiler
--  cannot read: a name that holds a quote -- a role a project configured,
--  say -- broke the whole list, and the shape of every definition was
--  whatever each concatenation happened to write. Here a parameter is a
--  record, a definition is its name, its description and its parameters,
--  and Definition writes the one shape, every string escaped.
--
--  Task safety: pure functions over their arguments.
package Model_Runner.Tools.Schemas is

   --  The values a parameter may take, where they are a fixed few.
   package Choice_Lists is new Ada.Containers.Indefinite_Vectors (Positive, String);

   --  No fixed few: any string.
   Any_Text : constant Choice_Lists.Vector := Choice_Lists.Empty_Vector;

   --  One parameter of a tool: a string or a whole number, named, required
   --  or not, and a string one of Choices where those are given.
   type Parameter is private;

   --  A string parameter.
   --
   --  @param Name What the model writes it as.
   --  @param Required Whether a call must give it.
   --  @param Choices The values it may take; Any_Text for any.
   --  @return The parameter.
   function Text
     (Name     : String;
      Required : Boolean := True;
      Choices  : Choice_Lists.Vector := Any_Text) return Parameter;

   --  A parameter that is a list of strings: a JSON array of them.
   --
   --  @param Name What the model writes it as.
   --  @param Required Whether a call must give it.
   --  @return The parameter.
   function Text_List
     (Name     : String;
      Required : Boolean := True) return Parameter;

   --  A whole-number parameter.
   --
   --  @param Name What the model writes it as.
   --  @param Required Whether a call must give it.
   --  @return The parameter.
   function Whole_Number
     (Name     : String;
      Required : Boolean := True) return Parameter;

   type Parameter_List is array (Positive range <>) of Parameter;

   --  A tool that takes nothing.
   No_Parameters : constant Parameter_List;

   --  A tool's definition as the model is offered it: the function's
   --  name, what it does, and an object of its parameters with the
   --  required ones named.
   --
   --  @param Name The function's name.
   --  @param Description What it does, for the model.
   --  @param Parameters What it takes.
   --  @return The JSON object.
   function Definition
     (Name        : String;
      Description : String;
      Parameters  : Parameter_List) return String;

   --  A string as JSON writes it: quoted, with every quote, backslash and
   --  control character escaped.
   --
   --  @param Item The string.
   --  @return The JSON string literal.
   function Quoted (Item : String) return String;

private

   type Parameter is record
      Name     : Ada.Strings.Unbounded.Unbounded_String;
      Required : Boolean := True;
      Choices  : Choice_Lists.Vector;
      Whole    : Boolean := False;
      List     : Boolean := False;
   end record;

   No_Parameters : constant Parameter_List (1 .. 0) := [others => <>];

end Model_Runner.Tools.Schemas;
