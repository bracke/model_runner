with Ada.Characters.Handling;
with Ada.Strings.Unbounded;
with Ada.Strings.Fixed;

with Model_Runner.Errors;
with Model_Runner.Framework.Configurations;
with Model_Runner.Framework.Records;

package body Model_Runner.Framework.Permissions is

   use Ada.Strings.Unbounded;
   use type Name_Lists.Vector;

   package E renames Model_Runner.Errors;

   function Trim (Text : String) return String
   is (Ada.Strings.Fixed.Trim (Text, Ada.Strings.Both));

   function Starts (Text, Prefix : String) return Boolean
   is (Text'Length >= Prefix'Length
       and then Text (Text'First .. Text'First + Prefix'Length - 1) = Prefix);

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
      Result : Permission_Set := Nothing;
   begin
      Present := False;
      Configurations.Read (Item, Config, Status);
      if E.Is_Error (Status) then
         return Result;
      end if;

      for Item_Kind in Capability loop
         declare
            Field : constant String := "map.permission." & Level & "." & Word (Item_Kind);
         begin
            if Records.Has (Config, Field) then
               Present := True;
               Result (Item_Kind).Granted := True;
               for Pair of Parts (Records.Get (Config, Field), ',') loop
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
                     if Key = "roots" then
                        Result (Item_Kind).Roots := Parts (Value, '|');
                     elsif Key = "deny" then
                        Result (Item_Kind).Deny := Parts (Value, '|');
                     elsif Key = "profiles" then
                        Result (Item_Kind).Profiles := Parts (Value, '|');
                     elsif Key = "max_depth" then
                        Result (Item_Kind).Max_Depth := Count;
                     elsif Key = "max_children" then
                        Result (Item_Kind).Max_Children := Count;
                     end if;
                  end;
               end loop;
            end if;
         end;
      end loop;
      return Result;
   end Level_Of;

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
            if Starts (A, B) and then not Result.Contains (A) then
               Result.Append (A);
            elsif Starts (B, A) and then not Result.Contains (B) then
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

   ---------------
   -- Effective --
   ---------------

   function Effective
     (Item    : Stores.Store;
      Kind    : String;
      Role    : String;
      Runtime : Permission_Set := Unrestricted) return Permission_Set
   is
      Present : Boolean;
      Project : Permission_Set := Level_Of (Item, "project", Present);
      Result  : Permission_Set;
   begin
      --  Least privilege, and enough to work: a project that says nothing
      --  lets its agents read and write source and specifications, run
      --  builds and tests, and hand a part of their work to at most two
      --  children one level down, and nothing more.
      if not Present then
         Project := Nothing;
         for Item_Kind in Read_Source .. Run_Tests loop
            Project (Item_Kind).Granted := True;
         end loop;
         Project (Create_Children) :=
           (Granted => True, Max_Depth => 1, Max_Children => 2, others => <>);
      end if;
      Result := Intersect (Project, Runtime);

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
         if Starts (Path, Denied) then
            return False;
         end if;
      end loop;
      return G.Roots.Is_Empty or else (for some Root of G.Roots => Starts (Path, Root));
   end Allows;

   --------------
   -- Widening --
   --------------

   function Widening (Wider, Than : Permission_Set) return String is
      Within : constant Permission_Set := Intersect (Wider, Than);
   begin
      for Item in Capability loop
         if Wider (Item).Granted
           and then (not Within (Item).Granted
                     or else Within (Item).Roots /= Wider (Item).Roots
                     or else Within (Item).Profiles /= Wider (Item).Profiles
                     or else Within (Item).Max_Depth /= Wider (Item).Max_Depth
                     or else Within (Item).Max_Children /= Wider (Item).Max_Children)
         then
            return Word (Item);
         end if;
      end loop;
      return "";
   end Widening;

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
            Tokens : constant Name_Lists.Vector := Parts (Line, ' ');
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

end Model_Runner.Framework.Permissions;
