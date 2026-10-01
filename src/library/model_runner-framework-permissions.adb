with Hostkit.Fs;
with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Characters.Handling;
with Ada.Strings.Unbounded;
with Ada.Strings.Fixed;
with Ada.Strings.Maps;

with Model_Runner.Framework.Configurations;

package body Model_Runner.Framework.Permissions is

   use Ada.Strings.Unbounded;
   use type Name_Lists.Vector;

   package E renames Model_Runner.Errors;

   function Trim (Text : String) return String
   is (Ada.Strings.Fixed.Trim (Text, Ada.Strings.Both));

   function Starts (Text, Prefix : String) return Boolean
   is (Text'Length >= Prefix'Length
       and then Text (Text'First .. Text'First + Prefix'Length - 1) = Prefix);

   --  A path as its parts say it: separators of either kind, no empty
   --  part and no ".", joined by "/" -- so ./src//x and src/x are one path,
   --  and no spelling of a path reaches past a rule written another way.
   function Normal (Path : String) return String is
      Result : Unbounded_String;
      Start  : Natural := Path'First;
   begin
      for Index in Path'First .. Path'Last + 1 loop
         if Index > Path'Last or else Path (Index) in '/' | '\' then
            if Index > Start and then Path (Start .. Index - 1) /= "." then
               Append (Result, (if Result = Null_Unbounded_String then "" else "/")
                               & Path (Start .. Index - 1));
            end if;
            Start := Index + 1;
         end if;
      end loop;
      return To_String (Result);
   end Normal;

   --  Whether a path lies at or under another, part by part: src/parser
   --  holds src/parser/x, and not src/parser_other.
   function Within (Path, Prefix : String) return Boolean is
      P : constant String := Normal (Path);
      R : constant String := Normal (Prefix);
   begin
      return R = "" or else P = R or else Starts (P, R & "/");
   end Within;

   ----------
   -- Word --
   ----------

   function Word (Item : Capability) return String
   is (Ada.Characters.Handling.To_Lower (Capability'Image (Item)));

   --  The parts of a text between separators, trimmed, empty ones left out.
   function Parts (Text : String; Separator : Character) return Name_Lists.Vector is
      Result : Name_Lists.Vector;
      Start  : Natural := Text'First;
   begin
      for Index in Text'First .. Text'Last + 1 loop
         if Index > Text'Last or else Text (Index) = Separator then
            if Trim (Text (Start .. Index - 1)) /= "" then
               Result.Append (Trim (Text (Start .. Index - 1)));
            end if;
            Start := Index + 1;
         end if;
      end loop;
      return Result;
   end Parts;

   --  A grant as its constraints are written: roots=A|B, deny=C|D,
   --  profiles=P|Q, max_depth=N, max_children=N, separated by commas.
   --  What of a grant's constraints this does not read: a key it has no
   --  constraint called, a word with nothing it belongs to, a count that
   --  is no number. Read as it stood, it would grant more than meant.
   function Constraint_Problem (Text : String) return String is
      Last_Key : Unbounded_String;
   begin
      for Pair of Parts (Ada.Strings.Fixed.Translate
                           (Text, Ada.Strings.Maps.To_Mapping (" ", ",")), ',')
      loop
         declare
            Equal : constant Natural := Ada.Strings.Fixed.Index (Pair, "=");
            Key   : constant String :=
              (if Equal = 0 then Trim (Pair) else Trim (Pair (Pair'First .. Equal - 1)));
            Value : constant String :=
              (if Equal = 0 then "" else Trim (Pair (Equal + 1 .. Pair'Last)));
         begin
            if Key = "" then
               null;
            elsif Equal = 0 and then To_String (Last_Key) in "roots" | "deny"
              and then Ada.Strings.Fixed.Index (Key, "/") = 0 and then Ada.Strings.Fixed.Index (Key, ".") = 0
            then
               --  A word after the roots that names no path is a slip, not a
               --  root: src/ or README.md are, bogus is not.
               return Key & " is no path: a root after " & To_String (Last_Key)
                 & "= is a directory, as src/, or a file, as README.md";
            elsif Equal = 0 and then To_String (Last_Key) in "roots" | "deny" | "profiles" then
               null;
            elsif Equal = 0 then
               return Key & " is no constraint: they are roots=, deny=, profiles=, max_depth= and"
                 & " max_children=; on grants a capability with none, off takes it away, and inherit"
                 & " follows the level above";
            elsif Key not in "roots" | "deny" | "profiles" | "max_depth" | "max_children" then
               return "no constraint is called " & Key & "; they are roots, deny, profiles,"
                 & " max_depth and max_children -- and on, off or inherit stand alone";
            elsif Key in "max_depth" | "max_children"
              and then (Value'Length not in 1 .. 9
                        or else (for some C of Value => C not in '0' .. '9'))
            then
               return Key & "=" & Value & " is no count";
            elsif Key in "roots" | "deny" | "profiles" and then Value = "" then
               return Key & "= names nothing";
            end if;
            --  A root is a place in the project, named from it.
            if Key in "roots" | "deny" or else (Equal = 0 and then To_String (Last_Key) in "roots" | "deny")
            then
               for Root of Parts ((if Equal = 0 then Key else Value), '|') loop
                  if Root'Length > 0
                    and then (Root (Root'First) = '/'
                              or else Root = ".." or else Ada.Strings.Fixed.Index (Root, "../") > 0)
                  then
                     return Root & " is outside the project: a root is a path within it, relative to"
                       & " it, as src/ or docs/";
                  end if;
               end loop;
            end if;
            if Equal > 0 then
               Last_Key := To_Unbounded_String (Key);
            end if;
         end;
      end loop;
      return "";
   end Constraint_Problem;

   function Constrained (Text : String) return Grant is
      Result : Grant := (Granted => True, others => <>);

      --  A word with no = after roots=, deny= or profiles= is one more of
      --  them: roots=docs/ src/ as roots=docs/|src/.
      Last_Key : Unbounded_String;
   begin
      --  A comma or a space apart: max_depth=1 max_children=2 as well.
      for Pair of Parts (Ada.Strings.Fixed.Translate
                           (Text, Ada.Strings.Maps.To_Mapping (" ", ",")), ',') loop
         declare
            Equal : constant Natural := Ada.Strings.Fixed.Index (Pair, "=");
            Key   : constant String :=
              (if Equal = 0 then Pair else Trim (Pair (Pair'First .. Equal - 1)));
            Value : constant String :=
              (if Equal = 0 then "" else Trim (Pair (Equal + 1 .. Pair'Last)));
            Count : constant Natural :=
              (if Value'Length in 1 .. 9
                 and then (for all C of Value => C in '0' .. '9')
               then Natural'Value (Value) else Natural'Last);
         begin
            if Equal = 0 and then To_String (Last_Key) in "roots" | "deny" | "profiles" then
               if To_String (Last_Key) = "roots" then
                  Result.Roots.Append (Pair);
               elsif To_String (Last_Key) = "deny" then
                  Result.Deny.Append (Pair);
               else
                  Result.Profiles.Append (Pair);
               end if;
               goto Next_Pair;
            end if;
            Last_Key := To_Unbounded_String (Key);
            if Key = "roots" then
               Result.Roots := Parts (Value, '|');
            elsif Key = "deny" then
               Result.Deny := Parts (Value, '|');
            elsif Key = "profiles" then
               Result.Profiles := Parts (Value, '|');
            elsif Key = "max_depth" then
               Result.Max_Depth := Count;
            elsif Key = "max_children" then
               Result.Max_Children := Count;
            end if;
         end;
         <<Next_Pair>>
      end loop;
      return Result;
   end Constrained;

   --------------
   -- Level_Of --
   --------------

   function Level_Of
     (Item    : Stores.Store;
      Level   : String;
      Present : out Boolean) return Permission_Set
   is
      Config : Records.Item;
      Status : E.Error_Info;
   begin
      Present := False;
      Configurations.Read (Item, Config, Status);
      if E.Is_Error (Status) then
         return Nothing;
      end if;
      return Level_Of (Config, Level, Present);
   end Level_Of;

   ---------------------
   -- Project_Default --
   ---------------------

   function Project_Default return Permission_Set is
      Result : Permission_Set := Nothing;
   begin
      for Item_Kind in Read_Source .. Run_Tests loop
         Result (Item_Kind).Granted := True;
      end loop;
      Result (Create_Children) :=
        (Granted => True, Max_Depth => 1, Max_Children => 2, others => <>);
      Result (Propose_Tasks).Granted := True;
      --  Static analysis reads and reports, as the tests do.
      Result (Run_Static_Analysis).Granted := True;
      return Result;
   end Project_Default;

   function Level_Of
     (Config  : Records.Item;
      Level   : String;
      Present : out Boolean) return Permission_Set
   is
      Result : Permission_Set := Nothing;
   begin
      Present := False;
      for Item_Kind in Capability loop
         declare
            Field : constant String := "map.permission." & Level & "." & Word (Item_Kind);
         begin
            if Records.Has (Config, Field) then
               Present := True;
               --  inherit: what the level above gives, read when it is
               --  asked -- the project's default for the project, and for
               --  a kind or role no narrowing of the level above at all.
               if Records.Get (Config, Field) = "inherit" then
                  Result (Item_Kind) :=
                    (if Level = "project" then Project_Default (Item_Kind)
                     else (Granted => True, others => <>));
               else
                  Result (Item_Kind) := Constrained (Records.Get (Config, Field));
               end if;
            end if;
         end;
      end loop;
      return Result;
   end Level_Of;

   --  The capability a word names, if any.
   procedure Named
     (Text  : String;
      Found : out Boolean;
      Which : out Capability) is
   begin
      Found := False;
      Which := Capability'First;
      for Item_Kind in Capability loop
         if Word (Item_Kind) = Ada.Characters.Handling.To_Lower (Trim (Text)) then
            Found := True;
            Which := Item_Kind;
            return;
         end if;
      end loop;
   end Named;

   ------------------
   -- Restriction --
   ------------------

   procedure Restriction
     (Text   : String;
      Result : out Permission_Set;
      Status : out Model_Runner.Errors.Error_Info) is
   begin
      Result := Nothing;
      Status := E.Success;
      --  As written -- write_source: roots=docs/, max_depth=1; read_source
      --  -- or as it is shown, a capability a line with its constraints
      --  after a space: write_source roots=docs/.
      for Entry_Text of Parts (Ada.Strings.Fixed.Translate
                                 (Text, Ada.Strings.Maps.To_Mapping ([1 => ASCII.LF], ";")), ';')
      loop
         declare
            Colon : constant Natural := Ada.Strings.Fixed.Index (Entry_Text, ":");
            Space : constant Natural := Ada.Strings.Fixed.Index (Entry_Text, " ");
            Cut   : constant Natural :=
              (if Colon = 0 then Space elsif Space = 0 then Colon else Natural'Min (Colon, Space));
            Name  : constant String :=
              (if Cut = 0 then Entry_Text else Entry_Text (Entry_Text'First .. Cut - 1));
            Rest  : constant String :=
              (if Cut = 0 then ""
               else Ada.Strings.Fixed.Translate
                      (Trim (Entry_Text (Cut + 1 .. Entry_Text'Last)),
                       Ada.Strings.Maps.To_Mapping (" ", ",")));
            Found : Boolean;
            Which : Capability;
         begin
            Named (Name, Found, Which);
            if not Found then
               Status := E.Make (E.Framework_Schema_Violation);
               E.Add_Text (Status, "name", "permissions");
               E.Add_Text (Status, "detail", "no capability is called " & Trim (Name)
                           & "; they are read_source, write_source, read_specs, write_specs,"
                           & " run_build, run_tests, run_static_analysis, create_children,"
                           & " propose_tasks, request_integration, use_network and"
                           & " execute_external_process, written as write_source roots=docs/;"
                           & " read_source");
               Result := Nothing;
               return;
            end if;
            if Constraint_Problem (Rest) /= "" then
               Status := E.Make (E.Framework_Schema_Violation);
               E.Add_Text (Status, "name", "permissions");
               E.Add_Text (Status, "detail", Trim (Name) & ": " & Constraint_Problem (Rest));
               Result := Nothing;
               return;
            end if;
            Result (Which) := Constrained (Rest);
         end;
      end loop;
   end Restriction;

   --------------------
   -- Allows_Profile --
   --------------------

   function Allows_Profile
     (Set     : Permission_Set;
      Item    : Capability;
      Profile : String) return Boolean
   is (Set (Item).Granted
       and then (Set (Item).Profiles.Is_Empty or else Set (Item).Profiles.Contains (Profile)));

   --  The narrower of two sets of prefixes: each prefix that lies inside
   --  one of the other's. Empty stands for everything.
   function Narrowest (Left, Right : Name_Lists.Vector) return Name_Lists.Vector is
      Result : Name_Lists.Vector;
   begin
      if Left.Is_Empty then
         return Right;
      elsif Right.Is_Empty then
         return Left;
      end if;
      for A of Left loop
         for B of Right loop
            if Within (A, B) and then not Result.Contains (A) then
               Result.Append (A);
            elsif Within (B, A) and then not Result.Contains (B) then
               Result.Append (B);
            end if;
         end loop;
      end loop;
      return Result;
   end Narrowest;

   ---------------
   -- Intersect --
   ---------------

   function Intersect (Left, Right : Permission_Set) return Permission_Set is
      Result : Permission_Set := Nothing;
   begin
      for Item in Capability loop
         declare
            L : Grant renames Left (Item);
            R : Grant renames Right (Item);
            G : Grant renames Result (Item);
         begin
            G.Granted := L.Granted and then R.Granted;
            if G.Granted then
               G.Roots := Narrowest (L.Roots, R.Roots);
               if not L.Roots.Is_Empty and then not R.Roots.Is_Empty
                 and then G.Roots.Is_Empty
               then
                  G.Granted := False;
               end if;

               G.Deny := L.Deny;
               for Path of R.Deny loop
                  if not G.Deny.Contains (Path) then
                     G.Deny.Append (Path);
                  end if;
               end loop;

               if L.Profiles.Is_Empty then
                  G.Profiles := R.Profiles;
               elsif R.Profiles.Is_Empty then
                  G.Profiles := L.Profiles;
               else
                  for Profile of L.Profiles loop
                     if R.Profiles.Contains (Profile) then
                        G.Profiles.Append (Profile);
                     end if;
                  end loop;
                  if G.Profiles.Is_Empty then
                     G.Granted := False;
                  end if;
               end if;

               G.Max_Depth := Natural'Min (L.Max_Depth, R.Max_Depth);
               G.Max_Children := Natural'Min (L.Max_Children, R.Max_Children);
            end if;
         end;
      end loop;
      return Result;
   end Intersect;

   -------------
   -- Sandbox --
   -------------

   --  The session's own confinement, set by /sandbox: below the shell's,
   --  never beside it.
   Session_Text : Unbounded_String;

   --  One confinement as its text says it: none for none, nothing for one
   --  that does not read.
   function Confinement (Text : String) return Permission_Set is
      Result : Permission_Set;
      Status : E.Error_Info;
   begin
      if Trim (Text) = "" then
         return Unrestricted;
      end if;
      Restriction (Text, Result, Status);
      return (if E.Is_Ok (Status) then Result else Nothing);
   end Confinement;

   --  What the shell set, where off -- as /sandbox off -- is no confinement.
   function Shell_Text return String
   is (if Ada.Environment_Variables.Exists (Sandbox_Variable)
         and then Trim (Ada.Environment_Variables.Value (Sandbox_Variable)) /= "off"
       then Ada.Environment_Variables.Value (Sandbox_Variable) else "");

   function Sandbox return Permission_Set is
      Shell   : constant Permission_Set := Confinement (Shell_Text);
      Session : constant Permission_Set := Confinement (To_String (Session_Text));
   begin
      if Shell = Unrestricted then
         return Session;
      elsif Session = Unrestricted then
         return Shell;
      end if;
      return Intersect (Shell, Session);
   end Sandbox;

   --------------------
   -- Sandbox_Source --
   --------------------

   function Sandbox_Source return String is
      Shell   : constant Boolean := Trim (Shell_Text) /= "";
      Session : constant Boolean := Trim (To_String (Session_Text)) /= "";
   begin
      return (if Shell and then Session then Sandbox_Variable & " and the session's /sandbox"
              elsif Shell then Sandbox_Variable
              elsif Session then "the session's /sandbox"
              else "");
   end Sandbox_Source;

   ---------------------
   -- Sandbox_Problem --
   ---------------------

   function Sandbox_Problem return String is
      Text   : constant String := Shell_Text;
      Result : Permission_Set;
      Status : E.Error_Info;
   begin
      if Trim (Text) = "" then
         return "";
      end if;
      Restriction (Text, Result, Status);
      return (if E.Is_Ok (Status) then "" else E.Text_Of (Status, "detail"));
   end Sandbox_Problem;

   ---------------------
   -- Sandbox_Refuses --
   ---------------------

   function Sandbox_Refuses (Path : String; Writing : Boolean) return Boolean is
      Confined : constant Permission_Set := Sandbox;
   begin
      if Confined = Unrestricted then
         return False;
      elsif Writing then
         return not Allows (Confined, Write_Source, Path)
           and then not Allows (Confined, Write_Specs, Path);
      else
         return not Allows (Confined, Read_Source, Path)
           and then not Allows (Confined, Read_Specs, Path);
      end if;
   end Sandbox_Refuses;

   -----------------
   -- Set_Sandbox --
   -----------------

   procedure Set_Sandbox
     (Text   : String;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Ignored : Permission_Set;
   begin
      Status := E.Success;
      if Trim (Text) = "" then
         Session_Text := Null_Unbounded_String;
         return;
      end if;
      Restriction (Text, Ignored, Status);
      if E.Is_Ok (Status) then
         Session_Text := To_Unbounded_String (Text);
      else
         --  Said as what it is: a sandbox that does not read.
         declare
            Why : constant String := E.Text_Of (Status, "detail");
         begin
            Status := E.Make (E.Framework_Input_Invalid);
            E.Add_Text (Status, "name", "the sandbox");
            E.Add_Text (Status, "value", Text);
            E.Add_Text (Status, "detail", Why & "; off lifts the sandbox");
         end;
      end if;
   end Set_Sandbox;

   ---------------
   -- Effective --
   ---------------

   function Effective
     (Item    : Stores.Store;
      Kind    : String;
      Role    : String;
      Runtime : Permission_Set := Unrestricted;
      Task_Level : String := "";
      Within_Sandbox : Boolean := True) return Permission_Set
   is
      Present : Boolean;
      Project : Permission_Set := Level_Of (Item, "project", Present);
      Result  : Permission_Set;
   begin
      --  Least privilege, and enough to work: a project that says nothing
      --  lets its agents read and write source and specifications, run
      --  builds and tests, propose tasks, and hand a part of their work to
      --  at most two children one level down, and nothing more.
      if not Present then
         Project := Project_Default;
      end if;
      Result := Intersect (Project, Runtime);
      if Within_Sandbox then
         Result := Intersect (Result, Sandbox);
      end if;

      if Kind /= "" then
         declare
            Level : constant Permission_Set := Level_Of (Item, "kind." & Kind, Present);
         begin
            if Present then
               Result := Intersect (Result, Level);
            end if;
         end;
      end if;
      if Role /= "" then
         declare
            Level : constant Permission_Set := Level_Of (Item, "role." & Role, Present);
         begin
            if Present then
               Result := Intersect (Result, Level);
            end if;
         end;
      end if;
      if Trim (Task_Level) /= "" then
         declare
            Level  : Permission_Set;
            Status : E.Error_Info;
         begin
            --  A restriction that does not read restricts to nothing: it was
            --  meant to narrow, and guessing at it could only widen.
            Restriction (Task_Level, Level, Status);
            Result := Intersect (Result, Level);
         end;
      end if;
      return Result;
   end Effective;

   ------------
   -- Allows --
   ------------

   function Allows
     (Set  : Permission_Set;
      Item : Capability;
      Path : String := "") return Boolean
   is
      G : Grant renames Set (Item);
   begin
      if not G.Granted then
         return False;
      elsif Path = "" then
         return True;
      end if;
      for Denied of G.Deny loop
         if Within (Path, Denied) then
            return False;
         end if;
      end loop;
      --  Specifications with no roots named are where specifications are
      --  kept -- docs/, doc/, specs/, spec/, or a Markdown file -- not every
      --  file: write_specs unscoped is no write_source unscoped.
      if G.Roots.Is_Empty and then Item = Write_Specs then
         return Within (Path, "docs/") or else Within (Path, "doc/")
           or else Within (Path, "specs/") or else Within (Path, "spec/")
           or else (Path'Length > 3 and then Path (Path'Last - 2 .. Path'Last) = ".md");
      end if;
      return G.Roots.Is_Empty or else (for some Root of G.Roots => Within (Path, Root));
   end Allows;

   --------------
   -- Widening --
   --------------

   function Widening (Wider, Than : Permission_Set) return String is
      Within : constant Permission_Set := Intersect (Wider, Than);
   begin
      --  What a level leaves unsaid -- no roots, no profiles, no limit --
      --  it takes from the level above: not wider for being unsaid.
      for Item in Capability loop
         if Wider (Item).Granted
           and then (not Within (Item).Granted
                     or else (not Wider (Item).Roots.Is_Empty
                              and then Within (Item).Roots /= Wider (Item).Roots)
                     or else (not Wider (Item).Profiles.Is_Empty
                              and then Within (Item).Profiles /= Wider (Item).Profiles)
                     or else (Wider (Item).Max_Depth /= Natural'Last
                              and then Within (Item).Max_Depth /= Wider (Item).Max_Depth)
                     or else (Wider (Item).Max_Children /= Natural'Last
                              and then Within (Item).Max_Children /= Wider (Item).Max_Children))
         then
            return Word (Item);
         end if;
      end loop;
      return "";
   end Widening;

   ---------------
   -- Widenings --
   ---------------

   function Widenings (Wider, Than : Permission_Set) return Name_Lists.Vector is
      Result : Name_Lists.Vector;
   begin
      for Item in Capability loop
         declare
            One : Permission_Set := Nothing;
         begin
            One (Item) := Wider (Item);
            if Widening (One, Than) /= "" then
               Result.Append (Word (Item));
            end if;
         end;
      end loop;
      return Result;
   end Widenings;

   -------------
   -- Clipped --
   -------------

   function Clipped (Asked, Allowed : Permission_Set) return String is
      Both   : constant Permission_Set := Intersect (Asked, Allowed);
      Result : Unbounded_String;
   begin
      for Name of Widenings (Asked, Allowed) loop
         declare
            Which : Capability := Capability'First;
         begin
            for Item in Capability loop
               if Word (Item) = Name then
                  Which := Item;
               end if;
            end loop;
            Append (Result, (if Result = Null_Unbounded_String then "" else ", ") & Name
                    & " (gets "
                    & (if not Both (Which).Granted then "none"
                       elsif Grant_Text (Both (Which)) = "" then "it"
                       else Grant_Text (Both (Which)))
                    & ")");
         end;
      end loop;
      return To_String (Result);
   end Clipped;

   ----------------
   -- Grant_Text --
   ----------------

   function Grant_Text (Given : Grant) return String is
      Result : Unbounded_String;

      procedure Add (Part : String) is
      begin
         Append (Result, (if Result = Null_Unbounded_String then "" else " ") & Part);
      end Add;

      function Joined (Items : Name_Lists.Vector) return String is
         Text : Unbounded_String;
      begin
         for Part of Items loop
            Append (Text, (if Text = Null_Unbounded_String then "" else "|") & Part);
         end loop;
         return To_String (Text);
      end Joined;
   begin
      if not Given.Roots.Is_Empty then
         Add ("roots=" & Joined (Given.Roots));
      end if;
      if not Given.Deny.Is_Empty then
         Add ("deny=" & Joined (Given.Deny));
      end if;
      if not Given.Profiles.Is_Empty then
         Add ("profiles=" & Joined (Given.Profiles));
      end if;
      if Given.Max_Depth /= Natural'Last then
         Add ("max_depth=" & Trim (Natural'Image (Given.Max_Depth)));
      end if;
      if Given.Max_Children /= Natural'Last then
         Add ("max_children=" & Trim (Natural'Image (Given.Max_Children)));
      end if;
      return To_String (Result);
   end Grant_Text;

   -----------
   -- Image --
   -----------

   function Image (Set : Permission_Set) return String is
      Result : Unbounded_String;

      function Joined (Items : Name_Lists.Vector) return String is
         Text : Unbounded_String;
      begin
         for Part of Items loop
            Append (Text, (if Text = Null_Unbounded_String then "" else "|") & Part);
         end loop;
         return To_String (Text);
      end Joined;
   begin
      for Item in Capability loop
         if Set (Item).Granted then
            Append (Result, Word (Item));
            if not Set (Item).Roots.Is_Empty then
               Append (Result, " roots=" & Joined (Set (Item).Roots));
            end if;
            if not Set (Item).Deny.Is_Empty then
               Append (Result, " deny=" & Joined (Set (Item).Deny));
            end if;
            if not Set (Item).Profiles.Is_Empty then
               Append (Result, " profiles=" & Joined (Set (Item).Profiles));
            end if;
            if Set (Item).Max_Depth /= Natural'Last then
               Append (Result, " max_depth=" & Trim (Natural'Image (Set (Item).Max_Depth)));
            end if;
            if Set (Item).Max_Children /= Natural'Last then
               Append (Result, " max_children="
                       & Trim (Natural'Image (Set (Item).Max_Children)));
            end if;
            Append (Result, ASCII.LF);
         end if;
      end loop;
      return To_String (Result);
   end Image;

   -----------
   -- Value --
   -----------

   function Value (Text : String) return Permission_Set is
      Result : Permission_Set := Nothing;
   begin
      for Line of Lines_Of (Text) loop
         declare
            --  Constraints are written "roots=A, deny=B", as Image writes
            --  them: the comma between is no part of the value before it.
            Tokens : constant Name_Lists.Vector :=
              Parts (Ada.Strings.Fixed.Translate
                       (Line, Ada.Strings.Maps.To_Mapping (",", " ")), ' ');
         begin
            for Item in Capability loop
               if not Tokens.Is_Empty and then Tokens.First_Element = Word (Item) then
                  Result (Item).Granted := True;
                  for Token of Tokens loop
                     declare
                        Equal : constant Natural := Ada.Strings.Fixed.Index (Token, "=");
                        Key   : constant String :=
                          (if Equal = 0 then "" else Token (Token'First .. Equal - 1));
                        Rest  : constant String :=
                          (if Equal = 0 then "" else Token (Equal + 1 .. Token'Last));
                     begin
                        if Key = "roots" then
                           Result (Item).Roots := Parts (Rest, '|');
                        elsif Key = "deny" then
                           Result (Item).Deny := Parts (Rest, '|');
                        elsif Key = "profiles" then
                           Result (Item).Profiles := Parts (Rest, '|');
                        elsif Key = "max_depth"
                          and then Rest'Length in 1 .. 9
                          and then (for all C of Rest => C in '0' .. '9')
                        then
                           Result (Item).Max_Depth := Natural'Value (Rest);
                        elsif Key = "max_children"
                          and then Rest'Length in 1 .. 9
                          and then (for all C of Rest => C in '0' .. '9')
                        then
                           Result (Item).Max_Children := Natural'Value (Rest);
                        end if;
                     end;
                  end loop;
               end if;
            end loop;
         end;
      end loop;
      return Result;
   end Value;

   function Permissions_Beside (Prompt_Path : String) return String
   is (Prompt_Path & ".permissions");

   ------------------
   -- Path_Refusal --
   ------------------

   function Path_Refusal
     (Root    : String;
      Path    : String;
      Writing : Boolean;
      Allowed : Permission_Set := Unrestricted) return String
   is
      --  The path it asked for, as the project would name it: its last
      --  part, which is what a model that began it with / most likely
      --  meant -- not an example it would take literally.
      function Last_Part return String is
         Slash : constant Natural :=
           Ada.Strings.Fixed.Index (Path, "/", Ada.Strings.Backward);
         Base  : constant String :=
           (if Root'Length > 0 and then Root (Root'Last) = '/' then Root else Root & "/");
      begin
         --  A whole path into the project is the part after it.
         if Path'Length > Base'Length
           and then Path (Path'First .. Path'First + Base'Length - 1) = Base
         then
            return Path (Path'First + Base'Length .. Path'Last);
         end if;
         --  A path through a directory called as the project is -- as a
         --  model guesses where the project lies -- is what follows it.
         declare
            Named : constant String :=
              "/" & Ada.Directories.Simple_Name (Ada.Directories.Full_Name (if Root = "" then "." else Root)) & "/";
            At_Name : constant Natural := Ada.Strings.Fixed.Index (Path, Named, Ada.Strings.Backward);
         begin
            if At_Name > 0 and then At_Name + Named'Length <= Path'Last then
               return Path (At_Name + Named'Length .. Path'Last);
            end if;
         exception
            when others =>
               null;
         end;
         --  The longest tail of it the project holds -- /x/project/src/a.adb
         --  is src/a.adb, not a.adb -- or, for a file not there yet, the
         --  longest whose directory is.
         for Pass in 1 .. 2 loop
            for Cut in Path'Range loop
               if Path (Cut) = '/' and then Cut < Path'Last then
                  declare
                     Tail  : constant String := Path (Cut + 1 .. Path'Last);
                     Whole : constant String := Base & Tail;
                  begin
                     if (Pass = 1 and then Ada.Directories.Exists (Whole))
                       or else (Pass = 2 and then Ada.Strings.Fixed.Index (Tail, "/") > 0
                                and then Ada.Directories.Exists
                                           (Ada.Directories.Containing_Directory (Whole)))
                     then
                        return Tail;
                     end if;
                  exception
                     when others =>
                        null;
                  end;
               end if;
            end loop;
         end loop;
         --  Its last part, for a file to be written; for one to be read,
         --  only where the project has it -- not a name that is no file.
         declare
            Tail : constant String :=
              (if Slash = 0 or else Slash = Path'Last then "" else Path (Slash + 1 .. Path'Last));
         begin
            return (if Writing or else (Tail /= "" and then Ada.Directories.Exists (Base & Tail)) then Tail
                    else "");
         exception
            when others =>
               return "";
         end;
      end Last_Part;

      Outside : constant String :=
        Path & " is outside the project; paths are relative to it"
        & (if Last_Part = "" then "" else ": try " & Last_Part & ", or list_directory . to see them");
      Parts   : Name_Lists.Vector;
      Start   : Natural := Path'First;

      function Under (Real, Base : String) return Boolean
      is (Real = Base
          or else (Real'Length > Base'Length
                   and then Real (Real'First .. Real'First + Base'Length - 1) = Base
                   and then Real (Real'First + Base'Length) in '/' | '\'));
   begin
      if Path'Length > 0
        and then (Path (Path'First) in '/' | '\' | '~'
                  or else (Path'Length > 1 and then Path (Path'First + 1) = ':'))
      then
         return Outside;
      end if;
      for Index in Path'First .. Path'Last + 1 loop
         if Index > Path'Last or else Path (Index) in '/' | '\' then
            if Index > Start and then Path (Start .. Index - 1) /= "." then
               Parts.Append (Path (Start .. Index - 1));
            end if;
            Start := Index + 1;
         end if;
      end loop;
      if Parts.Contains ("..") then
         return Outside;
      elsif not Parts.Is_Empty and then Parts.First_Element = State_Directory then
         return Path & " is the project's state, which only the harness reads and writes";
      elsif Writing and then Parts.Contains (".git") then
         return Path & " is version control, which only the harness writes";
      end if;

      --  Inside once every link on the way is followed: what of the path
      --  there is already, resolved, lies in the tree as the tree resolves,
      --  and not in the state.
      declare
         Base    : constant String := Hostkit.Fs.Real_Path (Root);
         Nearest : Unbounded_String :=
           To_Unbounded_String (Hostkit.Fs.Join (Root, (if Path = "" then "." else Path)));
      begin
         while not Ada.Directories.Exists (To_String (Nearest))
           and then To_String (Nearest)'Length > Root'Length
         loop
            Nearest := To_Unbounded_String (Ada.Directories.Containing_Directory (To_String (Nearest)));
         end loop;
         declare
            Real : constant String := Hostkit.Fs.Real_Path (To_String (Nearest));
         begin
            if Base = "" or else Real = "" or else not Under (Real, Base) then
               return Outside;
            elsif Under (Real, Hostkit.Fs.Join (Base, State_Directory)) then
               return Path & " is the project's state, which only the harness reads and writes";
            end if;
         end;
      exception
         when others =>
            return Outside;
      end;

      if Writing
        and then not Allows (Allowed, Write_Source, Path)
        and then not Allows (Allowed, Write_Specs, Path)
      then
         return "you may not write " & Path
           & (if Sandbox_Refuses (Path, True) then " (" & Sandbox_Source & " confines it)" else "");
      elsif not Writing
        and then not Allows (Allowed, Read_Source, Path)
        and then not Allows (Allowed, Read_Specs, Path)
      then
         return "you may not read " & Path
           & (if Sandbox_Refuses (Path, False) then " (" & Sandbox_Source & " confines it)" else "");
      end if;
      return "";
   end Path_Refusal;

   --------------
   -- In_Words --
   --------------

   function In_Words (Text : String) return String is
      Said  : Ada.Strings.Unbounded.Unbounded_String;
      Start : Natural := Text'First;

      --  The number after NAME= in a line, or "".
      function Value_Of (Line, Name : String) return String is
         At_Name : constant Natural := Ada.Strings.Fixed.Index (Line, Name & "=");
         Stop    : Natural;
      begin
         if At_Name = 0 then
            return "";
         end if;
         Stop := At_Name + Name'Length + 1;
         while Stop <= Line'Last and then Line (Stop) not in ' ' | ';' loop
            Stop := Stop + 1;
         end loop;
         return Line (At_Name + Name'Length + 1 .. Stop - 1);
      end Value_Of;

      procedure One (Raw : String) is
         Line  : constant String := Ada.Strings.Fixed.Trim (Raw, Ada.Strings.Both);
         Space : constant Natural := Ada.Strings.Fixed.Index (Line & " ", " ");
         Name  : constant String := Line (Line'First .. Space - 1);
         Roots : constant String :=
           Ada.Strings.Fixed.Translate (Value_Of (Line, "roots"), Ada.Strings.Maps.To_Mapping ("|", ","));
         Where : constant String := (if Roots = "" then "" else " in " & Roots);
         Most  : constant String := Value_Of (Line, "max_children");
         Words : constant String :=
           (if Name = "read_source" then "read the source"
            elsif Name = "read_specs" then "read the specifications"
            elsif Name = "write_source" then "write files" & Where
            elsif Name = "write_specs" then "write specifications" & Where
            elsif Name = "run_build" then "build it"
            elsif Name = "run_tests" then "run its tests"
            elsif Name = "run_static_analysis" then "run its static analysis"
            elsif Name = "create_children" then "make helpers" & (if Most = "" then "" else " (at most " & Most & ")")
            elsif Name = "propose_tasks" then "propose tasks"
            elsif Name = "use_network" then "use the network"
            else Line);
      begin
         if Line /= "" then
            Ada.Strings.Unbounded.Append
              (Said, (if Ada.Strings.Unbounded.Length (Said) = 0 then "" else ", ") & Words);
         end if;
      end One;
   begin
      for Index in Text'First .. Text'Last + 1 loop
         if Index > Text'Last or else Text (Index) in ';' | ASCII.LF then
            One (Text (Start .. Index - 1));
            Start := Index + 1;
         end if;
      end loop;
      return (if Ada.Strings.Unbounded.Length (Said) = 0 then "nothing"
              else Ada.Strings.Unbounded.To_String (Said));
   end In_Words;

end Model_Runner.Framework.Permissions;
