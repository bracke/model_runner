--  What a fixture written here has in common with a file somebody ships.
--
--  Every other check in this repository compares two implementations that
--  were written together: the engine against a reference transformer, both
--  reading a fixture built by `Tiny_Model`. That says a great deal about the
--  arithmetic and nothing at all about the model. Where the fixture and the
--  engine share a wrong idea, both sides agree and the sweep is silent --
--  which is exactly what happened to `gpt2`, whose loader required an
--  `output.bias` because the fixture wrote one, and whose fixture wrote one
--  because the loader asked. Twenty-six thousand conformance sequences could
--  not see it. The first published file refused in a second.
--
--  This compares the tensors a fixture writes against the tensors a real
--  file carries, by name, with layer indices folded together so that models
--  of different depths can be compared at all. Two answers come out of it:
--
--    names the published file carries that the fixture never writes -- work
--    the engine does for real models that no test here exercises
--
--    names the fixture writes that the published file does not carry -- the
--    fixture inventing a model nobody ships, which is the shape of the gpt2
--    defect
--
--  Neither is automatically a fault. A fixture is allowed to be smaller than
--  reality, and some tensors are genuinely optional. What is not allowed is
--  for the difference to go unlooked-at, which is what this reports.
--
--  Nothing is downloaded and no model is committed to this repository: the
--  caller supplies a path to a file already on the machine, and a missing
--  file is a skip.
--
--  Task safety: a comparison uses one task.
with Tiny_Model;

package Fixture_Likeness is

   --  How a comparison ended.
   type Outcome is
     (Skipped,       --  no file at the given path, or no fixture for it
      Rejected,      --  the container did not parse
      Compared);     --  both sides were read and the names lined up

   --  Longest tensor name this reports back. Names in the wild are short;
   --  one that is not is truncated rather than refused, because the count
   --  matters more than the spelling of the worst case.
   Name_Limit : constant := 64;

   --  What a comparison found.
   type Report is record
      Result : Outcome := Skipped;

      --  Which fixture was built to compare against, and in which shape.
      Kind  : Tiny_Model.Fixture_Architecture := Tiny_Model.Llama;
      Shape : Tiny_Model.Fixture_Shape := Tiny_Model.Plain;

      --  Distinct names on each side, after folding layer indices.
      Published : Natural := 0;
      Written   : Natural := 0;

      --  Names the published file carries and the fixture does not.
      Unwritten : Natural := 0;

      --  Names the fixture writes and the published file does not carry.
      Invented  : Natural := 0;

      --  The first of each, for a caller that prints one line.
      First_Unwritten      : String (1 .. Name_Limit) := [others => ' '];
      First_Unwritten_Last : Natural := 0;
      First_Invented       : String (1 .. Name_Limit) := [others => ' '];
      First_Invented_Last  : Natural := 0;

      Detail      : String (1 .. 256) := [others => ' '];
      Detail_Last : Natural := 0;
   end record;

   --  Compare a published file against the fixture for its architecture.
   --
   --  The shape follows the file: a model declaring experts is compared
   --  against the mixture fixture, anything else against the plain one.
   --  Comparing a dense file against a fixture carrying expert matrices
   --  would report every expert tensor as invented, which is true and
   --  useless.
   --
   --  @param Path Model file to read.
   --  @param Result What the comparison found.
   procedure Compare (Path : String; Result : out Report);

   --  Every tensor name the comparison saw on one side or the other.
   --
   --  Reported through a formal procedure rather than a list so that a
   --  caller may print them without this package deciding how, and so that
   --  nothing here allocates per name. Generic rather than an access type
   --  because the callers are nested inside the tool that prints, and an
   --  access-to-subprogram would not reach them.
   --
   --  @param Name Folded tensor name.
   --  @param In_File Whether the published file carries it.
   --  @param In_Fixture Whether the fixture writes it.
   generic
      with procedure Visit
        (Name : String; In_File : Boolean; In_Fixture : Boolean);

   --  Walk the names of the most recent comparison.
   procedure Each_Name;

   --  The one-line summary of a comparison.
   --
   --  @param Item Report to describe.
   --  @return Summary line, without a trailing newline.
   function Summary (Item : Report) return String;

   --  Detail text from a comparison.
   --
   --  @param Item Report to read.
   --  @return Detail text, or an empty string.
   function Detail_Text (Item : Report) return String
   is (Item.Detail (1 .. Item.Detail_Last));

end Fixture_Likeness;
