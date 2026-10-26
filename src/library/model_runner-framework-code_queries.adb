with Ada.Characters.Handling;
with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Model_Runner.Errors;
with Model_Runner.Framework.Retrieval;
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

   --------------
   -- Graph_Of --
   --------------

   function Graph_Of (Store : Stores.Store; Root : String) return Repository.Graph is
      Project : constant String := Ada.Directories.Containing_Directory (Stores.Root (Store));
   begin
      if Root = "" or else Root = "." or else Ada.Directories.Full_Name (Root) = Ada.Directories.Full_Name (Project)
      then
         return Repository.Now (Store);
      end if;
      return Repository.Scan (Root, Repository.Roots_Of (Store));
   end Graph_Of;

   --  What uses a file's units, from the graph as it is now; "" for nothing.
   function Users_Of_File (Store : Stores.Store; Path : String; Root : String := "") return String is
      package Rp renames Repository;
      Graph : constant Rp.Graph := Graph_Of (Store, Root);
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
      Failed : out Boolean;
      Root   : String := "") return String
   is
      package Rp renames Repository;
      package Tc renames Traceability;
      Graph : constant Rp.Graph := Graph_Of (Store, Root);
      Tree  : constant String :=
        (if Root = "" then Ada.Directories.Containing_Directory (Stores.Root (Store)) else Root);
      Have  : Boolean;
      Key   : constant String :=
        (if Named in "find_symbol" | "find_references" then "name"
         elsif Named = "impact" then "target" else "unit");
      Given : constant String := Model_Runner.Tools.Builtin.Text_Argument (Args, Key, Have);
      Said  : Unbounded_String;

      --  A file of the project, by its path within it -- wherever the
      --  caller's directory is.
      function Is_File (Path : String) return Boolean is
        (Path /= "" and then Ada.Directories.Exists (Tree & "/" & Path));

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
               Places : constant Name_Lists.Vector := Rp.References_To (Store, Graph, Name);
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

   --------------
   -- Retrieve --
   --------------

   function Retrieve
     (Store   : Stores.Store;
      Kind    : String;
      Query   : String;
      Root    : String;
      Records : Boolean;
      Failed  : out Boolean) return String
   is
      package Rv renames Retrieval;
      Tree  : constant String :=
        (if Root /= "" then Root else Ada.Directories.Containing_Directory (Stores.Root (Store)));
      Asked : constant String := Ada.Strings.Fixed.Trim (Query, Ada.Strings.Both);
      Said  : Unbounded_String;

      --  Whatever is said, held to the bound, the cut said.
      function Bounded (Text : String) return String
      is (if Text'Length <= Answer_Most then Text
          else Text (Text'First .. Text'First + Answer_Most - 1) & ASCII.LF
               & "(cut at" & Natural'Image (Answer_Most) & " characters: ask for less)");

      --  What the excerpts may fill of an answer, the rest kept for what
      --  is said after them: past it an excerpt is shown to its last whole
      --  line that fits, and what is not shown is named by a reference that
      --  shows it. Cut at the end instead, an answer lost the declarations
      --  after the first long one, and ended in the middle of a line.
      Room : constant Natural := Answer_Most - 1_500;

      --  The excerpts and lines not shown for room, each by its reference.
      Not_Shown : Unbounded_String;

      --  An excerpt as the agent is shown it: where from, then its lines
      --  numbered.
      procedure Show (Piece : Rv.Excerpt) is
         Text  : constant String := To_String (Piece.Text);
         Row   : Natural := Piece.First;
         Start : Positive := Text'First;
      begin
         if Length (Said) + 200 > Room then
            Append (Not_Shown, "  " & Rv.Reference (Piece) & " (" & Rv.Provenance (Piece) & ")" & ASCII.LF);
            return;
         end if;
         Append (Said, "-- " & Rv.Provenance (Piece) & ASCII.LF);
         for At_Char in Text'Range loop
            if Text (At_Char) = ASCII.LF then
               declare
                  Line : constant String := Image (Row) & ": " & Text (Start .. At_Char - 1) & ASCII.LF;
               begin
                  if Length (Said) + Line'Length > Room then
                     Append (Not_Shown, "  " & To_String (Piece.Path) & ":" & Image (Row) & "-" & Image (Piece.Last)
                             & "@" & To_String (Piece.Fingerprint) & " (the rest of the lines above)" & ASCII.LF);
                     return;
                  end if;
                  Append (Said, Line);
               end;
               Row := Row + 1;
               Start := At_Char + 1;
            end if;
         end loop;
      end Show;

      --  What was not shown for room, said before the answer ends.
      procedure Say_Not_Shown is
      begin
         if Length (Not_Shown) > 0 then
            Append (Said, "not shown for room -- find kind declaration with one of these shows it:" & ASCII.LF
                    & To_String (Not_Shown));
         end if;
      end Say_Not_Shown;

      function Shown (Path : String) return Boolean
      is (Model_Runner.Tools.Builtin.May_Read_Found (Path));

      --  What a refusal says, in the words it was given.
      function Why (Status : Model_Runner.Errors.Error_Info) return String
      is (if Model_Runner.Errors.Text_Of (Status, "detail") /= "" then Model_Runner.Errors.Text_Of (Status, "detail")
          else Model_Runner.Errors.Text_Of (Status, "name") & " is not in the project or will not read");
   begin
      Failed := False;
      if Asked = "" then
         Failed := True;
         return "error: find kind " & Kind & " takes a query";
      end if;
      if Kind = "search" then
         declare
            Graph : constant Repository.Graph := Graph_Of (Store, Root);
            Hits  : constant Rv.Hit_Lists.Vector :=
              Rv.Search (Store, Graph, Tree, Asked, Most => 15,
                         May_Read => Model_Runner.Tools.Builtin.May_Read_Found'Access, Records => Records);
            Rank  : Natural := 0;

            --  The files the search could not look in, a few named: what
            --  was not found may be in one of them. Only those the agent
            --  may read, as the hits are: named whatever its reads, a file
            --  it may not read was told it all the same.
            function Visible_Missed return Name_Lists.Vector is
               Result : Name_Lists.Vector;
            begin
               for One of Rv.Not_Searched (Graph, Tree) loop
                  declare
                     Colon : constant Natural := Ada.Strings.Fixed.Index (One, ": ");
                  begin
                     if Model_Runner.Tools.Builtin.May_Read_Found
                          (if Colon > One'First then One (One'First .. Colon - 1) else One)
                     then
                        Result.Append (One);
                     end if;
                  end;
               end loop;
               return Result;
            end Visible_Missed;

            function Left_Out return String is
               Missed : constant Name_Lists.Vector := Visible_Missed;
               Named  : Unbounded_String;
            begin
               if Missed.Is_Empty then
                  return "";
               end if;
               for At_Missed in 1 .. Natural'Min (5, Natural (Missed.Length)) loop
                  Append (Named, (if At_Missed = 1 then "" else "; ") & Missed (At_Missed));
               end loop;
               return "note:" & Natural'Image (Natural (Missed.Length)) & " files were not searched: "
                 & To_String (Named)
                 & (if Natural (Missed.Length) > 5
                    then "; and" & Natural'Image (Natural (Missed.Length) - 5) & " more" else "")
                 & ASCII.LF;
            end Left_Out;

            Note : constant String := Left_Out;
         begin
            if Hits.Is_Empty then
               return "nothing in the project for " & Asked & (if Note = "" then "" else ASCII.LF & Note);
            end if;
            for One of Hits loop
               Rank := Rank + 1;
               declare
                  Entry_Text : constant String :=
                    Image (Rank) & ". "
                    & (case One.Kind is
                         when Rv.Symbol_Hit => To_String (One.What) & " " & To_String (One.Name) & " at "
                                               & To_String (One.Path) & ":" & Image (One.Line),
                         when Rv.File_Hit   => "file " & To_String (One.Name) & " (" & To_String (One.What) & ")",
                         when Rv.Record_Hit => To_String (One.Name) & " " & To_String (One.What),
                         when Rv.Text_Hit   => "text " & To_String (One.Path) & ":" & Image (One.Line) & ": "
                                               & To_String (One.What))
                    & " -- score" & Natural'Image (One.Score) & ": " & To_String (One.Why)
                    & " [" & To_String (One.Authority) & "]" & ASCII.LF;
               begin
                  --  Whole hits only, as many as leave room for what is
                  --  said after them: cut at the end, the last ended
                  --  part-way through its path.
                  if Length (Said) + Entry_Text'Length > Room then
                     Append (Said, "and" & Natural'Image (Natural (Hits.Length) - Rank + 1)
                             & " more hits not shown for room -- a narrower query shows them" & ASCII.LF);
                     exit;
                  end if;
                  Append (Said, Entry_Text);
               end;
            end loop;
            Append (Said, Note);
            Append (Said, "find kind declaration with a name or PATH:LINE shows its lines" & ASCII.LF);
            return Bounded (To_String (Said));
         end;
      elsif Kind = "declaration" then
         declare
            At_Sign : constant Natural := Ada.Strings.Fixed.Index (Asked, "@", Ada.Strings.Backward);
            Colon   : constant Natural := Ada.Strings.Fixed.Index (Asked, ":", Ada.Strings.Backward);
            Status  : Model_Runner.Errors.Error_Info;
            Piece   : Rv.Excerpt;
         begin
            if At_Sign > 0 then
               --  A reference: the lines it named, while the file is still
               --  what they were cut from.
               if not Shown (Asked (Asked'First .. Natural'Max (Asked'First, Colon) - 1)) then
                  Failed := True;
                  return "error: " & Asked & " is not yours to read";
               end if;
               Rv.Expand (Tree, Asked, 200, Piece, Status);
               if Model_Runner.Errors.Is_Error (Status) then
                  Failed := True;
                  return "error: " & Why (Status);
               end if;
               Show (Piece);
            elsif Colon > Asked'First and then Colon < Asked'Last
              and then (for all C of Asked (Colon + 1 .. Asked'Last) => C in '0' .. '9')
              and then Asked'Last - Colon <= 7
            then
               --  PATH:LINE: the declaration holding the line.
               if not Shown (Asked (Asked'First .. Colon - 1)) then
                  Failed := True;
                  return "error: " & Asked (Asked'First .. Colon - 1) & " is not yours to read";
               end if;
               --  Line 0 is no line: said, where it was taken to be one and
               --  raised into the tool's caller.
               if Natural'Value (Asked (Colon + 1 .. Asked'Last)) = 0 then
                  Failed := True;
                  return "error: " & Asked & " names line 0; a file's lines are numbered from 1";
               end if;
               Rv.Around (Tree, Asked (Asked'First .. Colon - 1), Natural'Value (Asked (Colon + 1 .. Asked'Last)),
                          120, Piece, Status);
               if Model_Runner.Errors.Is_Error (Status) then
                  Failed := True;
                  return "error: " & Why (Status);
               end if;
               Show (Piece);
            else
               declare
                  Found : Rv.Excerpt_Lists.Vector;
               begin
                  Rv.Declaration (Graph_Of (Store, Root), Tree, Asked, 120, Found, Status,
                                  May_Read => Model_Runner.Tools.Builtin.May_Read_Found'Access);
                  if Found.Is_Empty then
                     Failed := True;
                     return "nothing in the project's graph declares " & Asked
                       & "; find kind search finds what is near it";
                  end if;
                  for One of Found loop
                     Show (One);
                  end loop;
               end;
            end if;
            Say_Not_Shown;
            Append (Said, "an excerpt's ref, given to find kind declaration, shows those lines again"
                    & " while the file is unchanged; read_file reads more" & ASCII.LF);
            return Bounded (To_String (Said));
         end;
      end if;
      Failed := True;
      return "error: find kind " & Kind & " is neither search nor declaration";
   end Retrieve;

   ----------
   -- Find --
   ----------

   function Find
     (Store  : Stores.Store;
      Kind   : String;
      Query  : String;
      Failed : out Boolean;
      Root   : String := "") return String
   is
      package Sc renames Model_Runner.Tools.Schemas;
      Named : constant String :=
        (if Kind = "symbol" then "find_symbol" elsif Kind = "references" then "find_references"
         elsif Kind = "depends_on" then "dependencies" elsif Kind = "used_by" then "dependents"
         elsif Kind = "impact" then "impact" else "");
      Key   : constant String :=
        (if Kind in "symbol" | "references" then "name" elsif Kind = "impact" then "target" else "unit");
   begin
      if Kind in "search" | "declaration" then
         return Retrieve (Store, Kind, Query, Root, Records => True, Failed => Failed);
      elsif Named = "" then
         Failed := True;
         return "error: find takes kind symbol, references, depends_on, used_by, impact, search, declaration"
           & " or text -- not " & Kind;
      end if;
      declare
         Said    : constant String :=
           Answer (Store, Named, "{" & Sc.Quoted (Key) & ": " & Sc.Quoted (Query) & "}", Failed, Root);
         Nothing : constant String := "nothing in the project's graph for ";
      begin
         --  A name the graph does not hold: a model guessing at one -- a
         --  procedure said by what it does, named move_balance, add_entry,
         --  update_balance in turn -- is shown what a search of its words
         --  finds, the first five, rather than told nothing again.
         if Kind = "symbol" and then Said'Length >= Nothing'Length
           and then Said (Said'First .. Said'First + Nothing'Length - 1) = Nothing
         then
            declare
               Searched : Boolean;
               Found    : constant String := Retrieve (Store, "search", Query, Root, Records => False,
                                                       Failed => Searched);
               Lines    : Natural := 0;
               Cut      : Natural := Found'Last;
               Whole    : Boolean := True;
            begin
               if Searched or else Found'Length = 0
                 or else Ada.Strings.Fixed.Index (Found, "nothing in the project for") = 1
               then
                  return Said;
               end if;
               for At_Char in Found'Range loop
                  if Found (At_Char) = ASCII.LF then
                     Lines := Lines + 1;
                     if Lines = 5 and then At_Char < Found'Last then
                        Cut := At_Char;
                        Whole := False;
                        exit;
                     end if;
                  end if;
               end loop;
               --  Cut, the search's own last line -- how to see a hit's
               --  lines -- is said again.
               return Said & "; no symbol is named so, and a search for its words finds:" & ASCII.LF
                 & Found (Found'First .. Cut)
                 & (if Whole then "" else "find kind declaration with a name or PATH:LINE shows its lines" & ASCII.LF);
            end;
         end if;
         return Said;
      end;
   end Find;

end Model_Runner.Framework.Code_Queries;
