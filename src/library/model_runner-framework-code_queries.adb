with Ada.Characters.Handling;
with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Model_Runner.Framework.Traceability;
with Model_Runner.Tools.Builtin;
with Model_Runner.Tools.Schemas;

package body Model_Runner.Framework.Code_Queries is

   use Ada.Strings.Unbounded;

   function Image (Value : Natural) return String is
      Raw : constant String := Natural'Image (Value);
   begin
      return Raw (Raw'First + 1 .. Raw'Last);
   end Image;

   --  The units a file declares, as the graph knows them: its packages,
   --  or the file itself where it declares none.
   function Units_Of_File
     (Graph : Repository.Graph;
      Path  : String) return Name_Lists.Vector
   is
      package Rp renames Repository;
      Units : Name_Lists.Vector;
      Least : Natural := Natural'Last;

      --  A unit's declaration: a package, or a body, named with the fewest
      --  dots in the file -- a unit that is a subprogram of its own.
      function Unit_Kind (Kind : String) return Boolean is (Kind in "package" | "body");

      function Dots (Name : String) return Natural is
        (Ada.Strings.Fixed.Count (Name, "."));
   begin
      --  An Ada body is its spec's unit: the graph keeps a body's
      --  subprograms, not the body.
      if Path'Length > 4 and then Path (Path'Last - 3 .. Path'Last) = ".adb" then
         declare
            Spec : constant String := Path (Path'First .. Path'Last - 1) & "s";
         begin
            for Index in 1 .. Rp.Symbol_Count (Graph) loop
               if To_String (Rp.Symbol_At (Graph, Index).Path) = Spec then
                  return Units_Of_File (Graph, Spec);
               end if;
            end loop;
         end;
      end if;
      for Index in 1 .. Rp.Symbol_Count (Graph) loop
         declare
            One : constant Rp.Symbol := Rp.Symbol_At (Graph, Index);
         begin
            if To_String (One.Path) = Path and then Unit_Kind (To_String (One.Kind)) then
               Least := Natural'Min (Least, Dots (To_String (One.Name)));
            end if;
         end;
      end loop;
      for Index in 1 .. Rp.Symbol_Count (Graph) loop
         declare
            One : constant Rp.Symbol := Rp.Symbol_At (Graph, Index);
         begin
            if To_String (One.Path) = Path and then Unit_Kind (To_String (One.Kind))
              and then Dots (To_String (One.Name)) = Least
              and then not Units.Contains (To_String (One.Name))
            then
               Units.Append (To_String (One.Name));
            end if;
         end;
      end loop;
      if Units.Is_Empty then
         Units.Append (Path);
      end if;
      return Units;
   end Units_Of_File;

   --  What uses a file's units, from the graph as it is now; "" for nothing.
   function Users_Of_File (Store : Stores.Store; Path : String) return String is
      package Rp renames Repository;
      Graph : constant Rp.Graph := Rp.Now (Store);
      Said  : Unbounded_String;
      Shown : Natural := 0;
   begin
      for Unit of Units_Of_File (Graph, Path) loop
         for User of Rp.Dependents_Of (Graph, Unit) loop
            if Shown < 20 and then Index (Said, User) = 0 then
               Append (Said, (if Said = Null_Unbounded_String then "" else ", ") & User);
               Shown := Shown + 1;
            end if;
         end loop;
      end loop;
      return To_String (Said);
   end Users_Of_File;

   --  A question to the project's repository graph, answered from the graph
   --  as it is now -- brought up to date first, so an answer after a write
   --  is about the code as written.
   function Answer
     (Store  : Stores.Store;
      Named  : String;
      Args   : String;
      Failed : out Boolean) return String
   is
      package Rp renames Repository;
      package Tc renames Traceability;
      Graph : constant Rp.Graph := Rp.Now (Store);
      Have  : Boolean;
      Key   : constant String :=
        (if Named in "find_symbol" | "find_references" then "name"
         elsif Named = "impact" then "target" else "unit");
      Given : constant String := Model_Runner.Tools.Builtin.Text_Argument (Args, Key, Have);
      Said  : Unbounded_String;

      --  A file of the project, by its path within it -- wherever the
      --  caller's directory is.
      function Is_File (Path : String) return Boolean is
        (Path /= ""
         and then Ada.Directories.Exists
                    (Ada.Directories.Containing_Directory (Stores.Root (Store)) & "/" & Path));

      function Listed (Items : Name_Lists.Vector; Most : Positive) return String is
         Text  : Unbounded_String;
         Count : Natural := 0;
      begin
         for One of Items loop
            Count := Count + 1;
            exit when Count > Most;
            Append (Text, One & ASCII.LF);
         end loop;
         if Natural (Items.Length) > Most then
            Append (Text, "(" & Image (Most) & " of" & Natural'Image (Natural (Items.Length)) & ")" & ASCII.LF);
         end if;
         return To_String (Text);
      end Listed;

      --  A unit, or a file's units.
      function Units return Name_Lists.Vector is
      begin
         if Is_File (Given) then
            return Units_Of_File (Graph, Given);
         end if;
         return Result : Name_Lists.Vector do
            Result.Append (Given);
         end return;
      end Units;
   begin
      Failed := False;
      if not Have or else Given = "" then
         Failed := True;
         return "error: " & Named & " needs a " & Key;
      end if;
      if Named = "find_symbol" then
         --  Every declaration of each name it matches: a spec and its body
         --  are two places, both said.
         for Name of Rp.Find_Symbols (Graph, Given) loop
            for Index in 1 .. Rp.Symbol_Count (Graph) loop
               declare
                  One : constant Rp.Symbol := Rp.Symbol_At (Graph, Index);
               begin
                  if To_String (One.Name) = Name then
                     Append (Said, To_String (One.Kind) & " " & Name & "  " & To_String (One.Path) & ":"
                             & Image (One.Line) & ASCII.LF);
                  end if;
               end;
            end loop;
            exit when Length (Said) > 8_000;
         end loop;
      elsif Named = "find_references" then
         for Name of Rp.Find_Symbols (Graph, Given) loop
            declare
               Places : constant Name_Lists.Vector := Rp.References_To (Graph, Name);
            begin
               if not Places.Is_Empty then
                  Append (Said, Name & ":" & ASCII.LF & Listed (Places, 100));
               end if;
            end;
            exit when Length (Said) > 8_000;
         end loop;
      elsif Named in "dependencies" | "dependents" then
         for Unit of Units loop
            declare
               Found : constant Name_Lists.Vector :=
                 (if Named = "dependencies" then Rp.Dependencies_Of (Graph, Unit)
                  else Rp.Dependents_Of (Graph, Unit));
            begin
               if not Found.Is_Empty then
                  Append (Said, Unit & (if Named = "dependencies" then " uses:" else " is used by:") & ASCII.LF
                          & Listed (Found, 100));
               end if;
            end;
         end loop;
      else
         --  A file as itself, a name as its symbol.
         declare
            Node    : Name_Lists.Vector;
            Matches : constant Name_Lists.Vector := Rp.Find_Symbols (Graph, Given);
         begin
            if Is_File (Given) then
               Node.Append (Given);
            elsif not Matches.Is_Empty then
               Node.Append ("symbol:" & Matches.First_Element);
            end if;
            if not Node.Is_Empty then
               declare
                  Reach : constant Tc.Impact := Tc.Impact_Of (Tc.Build (Store, Graph), Node);
               begin
                  for Index in 1 .. Natural'Min (Tc.Length (Reach), 100) loop
                     declare
                        One : constant Tc.Reached := Tc.Element (Reach, Index);
                     begin
                        Append (Said, To_String (One.Kind) & " " & To_String (One.Id) & " ("
                                & Ada.Characters.Handling.To_Lower (Rp.Confidence'Image (One.Sure)) & ")"
                                & ASCII.LF);
                     end;
                  end loop;
               end;
            end if;
         end;
      end if;
      --  A unit the graph holds with nothing on the side asked is an
      --  answer, not an absence: said as one, with the other direction
      --  named. "Nothing in the graph for Calc", said of what Calc uses, a
      --  model took for "nothing uses Calc", when Main did.
      if Said = Null_Unbounded_String
        and then Named in "dependencies" | "dependents"
        and then (if Is_File (Given) then not Units.Is_Empty
                  else not Rp.Find_Symbols (Graph, Given).Is_Empty)
      then
         return (if Named = "dependencies"
                 then Given & " depends on no unit of the project; find kind used_by says what uses it"
                 else "no unit of the project uses " & Given
                      & "; find kind depends_on says what it uses");
      end if;
      return (if Said = Null_Unbounded_String
              then "nothing in the project's graph for " & Given
              else To_String (Said));
   end Answer;

   ----------
   -- Find --
   ----------

   function Find
     (Store  : Stores.Store;
      Kind   : String;
      Query  : String;
      Failed : out Boolean) return String
   is
      package Sc renames Model_Runner.Tools.Schemas;
      Named : constant String :=
        (if Kind = "symbol" then "find_symbol" elsif Kind = "references" then "find_references"
         elsif Kind = "depends_on" then "dependencies" elsif Kind = "used_by" then "dependents"
         elsif Kind = "impact" then "impact" else "");
      Key   : constant String :=
        (if Kind in "symbol" | "references" then "name" elsif Kind = "impact" then "target" else "unit");
   begin
      if Named = "" then
         Failed := True;
         return "error: find takes kind symbol, references, depends_on, used_by, impact or text -- not " & Kind;
      end if;
      return Answer (Store, Named, "{" & Sc.Quoted (Key) & ": " & Sc.Quoted (Query) & "}", Failed);
   end Find;

end Model_Runner.Framework.Code_Queries;
