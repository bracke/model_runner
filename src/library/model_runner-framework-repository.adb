with Interfaces;
with System.Multiprocessors;
with Ada.Unchecked_Deallocation;
with Ada.Calendar;
with Ada.Characters.Handling;
with Ada.Containers.Indefinite_Hashed_Sets;
with Ada.Directories;
with Ada.Exceptions;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Maps;

with Hostkit.Fs;
with Hostkit.Metadata;

with Model_Runner.Framework.Configurations;
with Model_Runner.Framework.Files;
with Model_Runner.Framework.Repository.Languages;
with Model_Runner.Framework.Schemas;

package body Model_Runner.Framework.Repository is

   use Ada.Strings.Unbounded;

   package E renames Model_Runner.Errors;
   package Dirs renames Ada.Directories;
   use type Dirs.File_Kind;

   package Sorting is new Name_Lists.Generic_Sorting;

   Index_Name : constant String := "repository";
   Tab        : constant Character := ASCII.HT;

   --  Why a file or directory could not be read, from what stopped it:
   --  gone, not to be opened, or whatever else, by its name.
   function Why (Failure : Ada.Exceptions.Exception_Occurrence) return String is
      use Ada.Exceptions;
   begin
      if Exception_Identity (Failure) = Ada.IO_Exceptions.Name_Error'Identity then
         return "not there any more";
      elsif Exception_Identity (Failure) = Ada.IO_Exceptions.Use_Error'Identity then
         return "may not be opened";
      end if;
      return Exception_Name (Failure)
        & (if Exception_Message (Failure) = "" then "" else " " & Exception_Message (Failure));
   end Why;

   Link_Not_Followed : constant String := "a link to a directory, not followed";

   --  Files larger than this are recorded and not read.
   Largest_Read : constant := 4 * 1024 * 1024;

   --  A file's size and when it last changed, as seconds since the epoch.
   function Stamp_Of (Full : String) return String is
      use type Ada.Calendar.Time;
      --  The file system's own change record, to the nanosecond, where the
      --  host keeps one (statx): size and whole seconds alone kept the old
      --  content of a file rewritten the same size within the second it was
      --  last read in -- the agent's own tools already stamp so.
      Fine    : Boolean;
      Changed : constant String := Hostkit.Metadata.Change_Stamp (Full, Fine);

      --  The words of the record, a space between: its modification time's
      --  seconds with their point, its nanoseconds, its change time's the
      --  same, its size and its file number.
      function Word (Which : Positive) return String is
         Count : Natural := 0;
         Start : Natural := 0;
      begin
         for Index in Changed'Range loop
            if Changed (Index) /= ' ' and then (Index = Changed'First or else Changed (Index - 1) = ' ') then
               Count := Count + 1;
               Start := Index;
            end if;
            if Count = Which and then Changed (Index) /= ' '
              and then (Index = Changed'Last or else Changed (Index + 1) = ' ')
            then
               return Changed (Start .. Index);
            end if;
         end loop;
         return "";
      end Word;
   begin
      --  One look where the record says it all: its size, and its whole
      --  seconds -- what a stamp leads with -- are in it. Each file a scan
      --  walks was looked at three times for its stamp.
      if Fine and then Word (5) /= "" and then Ada.Strings.Fixed.Index (Word (1), ".") > 1 then
         return Word (5) & ":" & Word (1) (Word (1)'First .. Ada.Strings.Fixed.Index (Word (1), ".") - 1)
           & ":" & Changed;
      end if;
      declare
         Seconds : constant Duration :=
           Dirs.Modification_Time (Full) - Ada.Calendar.Time_Of (1970, 1, 1);
      begin
         return Ada.Strings.Fixed.Trim (Dirs.File_Size'Image (Dirs.Size (Full)), Ada.Strings.Both)
           & ":" & Ada.Strings.Fixed.Trim (Long_Long_Integer'Image (Long_Long_Integer (Seconds)),
                                           Ada.Strings.Both)
           & (if Fine then ":" & Changed else "");
      end;
   exception
      when others =>
         return "";
   end Stamp_Of;

   --  Whether a stamp says a file changed so lately that one of the same
   --  moment could still follow unseen: within two seconds, read again
   --  whatever the stamp -- a fine change record is a kernel tick coarse,
   --  and two writes of one size in one tick share it.
   function Recent (Stamp : String) return Boolean is
      use type Ada.Calendar.Time;
      Colon : constant Natural := Ada.Strings.Fixed.Index (Stamp, ":");
      Fine  : constant Natural :=
        (if Colon = 0 then 0 else Ada.Strings.Fixed.Index (Stamp (Colon + 1 .. Stamp'Last), ":"));
      Now   : constant Long_Long_Integer :=
        Long_Long_Integer (Ada.Calendar.Clock - Ada.Calendar.Time_Of (1970, 1, 1));
   begin
      return Colon = 0
        or else Now - Long_Long_Integer'Value
                        (Stamp (Colon + 1 .. (if Fine = 0 then Stamp'Last else Fine - 1))) < 2;
   exception
      when others =>
         return True;
   end Recent;

   --  A stamp as a graph records it: as it is where it can be trusted to
   --  move with any later write -- the host's own change record, taken two
   --  seconds or more after the change it shows, so a write after has a
   --  later time -- and marked "?" where it cannot: taken within those two
   --  seconds, with no change record, or none at all. A marked stamp says
   --  only that the file's text must be looked at to know it unchanged.
   function Recorded (Stamp : String) return String is
      Colons : constant Natural := Ada.Strings.Fixed.Count (Stamp, ":");
   begin
      return (if Colons >= 2 and then not Recent (Stamp) then Stamp else "?" & Stamp);
   end Recorded;

   function Lower (Text : String) return String
   renames Ada.Characters.Handling.To_Lower;

   function Image (Value : Natural) return String
   is (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   --  The words of a list, parted by spaces, commas or lines.
   function Split (Text : String) return Name_Lists.Vector is
      Result : Name_Lists.Vector;
      Start  : Natural := Text'First;
   begin
      for Index in Text'First .. Text'Last + 1 loop
         if Index > Text'Last or else Text (Index) in ' ' | ',' | ASCII.LF | ASCII.CR | ASCII.HT then
            if Index > Start then
               Result.Append (Text (Start .. Index - 1));
            end if;
            Start := Index + 1;
         end if;
      end loop;
      return Result;
   end Split;

   --  A path without the slashes around it.
   function Trim_Slashes (Path : String) return String
   is (Ada.Strings.Fixed.Trim
         (Path, Ada.Strings.Maps.To_Set ("/"), Ada.Strings.Maps.To_Set ("/")));

   function Sorted (Items : Name_Lists.Vector) return Name_Lists.Vector is
      Result : Name_Lists.Vector := Items;
   begin
      Sorting.Sort (Result);
      return Result;
   end Sorted;

   ---------------------------------------------------------------------------
   --  Building a graph.
   ---------------------------------------------------------------------------

   procedure Add_File (Into : in out Graph; Item : File_Entry) is
   begin
      Into.Files.Append (Item);
   end Add_File;

   procedure Add_Symbol (Into : in out Graph; Item : Symbol) is
      Full : constant String := To_String (Item.Name);
      Dot  : constant Natural :=
        Ada.Strings.Fixed.Index (Full, ".", Ada.Strings.Backward);
   begin
      Into.Symbols.Append (Item);

      --  A symbol inside a unit is that unit's declaration.
      if Dot > 0 then
         Into.Relations.Append
           (Relation'(Kind   => Declares,
                      From   => To_Unbounded_String (Full (Full'First .. Dot - 1)),
                      To     => Item.Name,
                      Source => Explicit,
                      Sure   => Certain,
                      Where  => To_Unbounded_String
                                  (To_String (Item.Path) & ":"
                                   & Image (Item.Line)),
                      Origin => Item.Path));
      end if;
   end Add_Symbol;

   --  Each name the graph's relations say -- the file or unit a relation
   --  is from, the name it is to, the file whose reading found it -- held
   --  once and shared, where every relation held its own copy: a tree of
   --  2.5 million references said 1,162 paths and 17,000 names over and
   --  over, and its graph took 1.7 GB of a session. A copy of an
   --  unbounded string shares its text, so the graph's later copies share
   --  them too. Where, a path and a line, is each relation's own.
   package Shared_Names is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type => String, Element_Type => Unbounded_String,
      Hash => Ada.Strings.Hash, Equivalent_Keys => "=");

   --  Text as a name held once in Held: the copy already there, or this
   --  one, kept for the next.
   function Shared (Held : in out Shared_Names.Map; Text : String) return Unbounded_String is
      Place : constant Shared_Names.Cursor := Held.Find (Text);
   begin
      if Shared_Names.Has_Element (Place) then
         return Shared_Names.Element (Place);
      end if;
      declare
         Made : constant Unbounded_String := To_Unbounded_String (Text);
      begin
         Held.Insert (Text, Made);
         return Made;
      end;
   end Shared;

   procedure Share_Names (Found : in out Graph) is
      Held : Shared_Names.Map;

      --  The last relation's file and finder: the next is mostly from the
      --  same, taken without asking Held -- asked for all three, a graph
      --  of 2.5 million relations took two seconds.
      Last_From, Last_Origin : Unbounded_String;

      procedure Share (Name : in out Unbounded_String) is
      begin
         Name := Shared (Held, To_String (Name));
      end Share;

      procedure Share_As_Last (Name : in out Unbounded_String; Last : in out Unbounded_String) is
      begin
         if Name /= Last then
            Share (Name);
            Last := Name;
         else
            Name := Last;
         end if;
      end Share_As_Last;
   begin
      for Index in 1 .. Natural (Found.Relations.Length) loop
         declare
            Link : Relation renames Found.Relations.Reference (Index);
         begin
            Share_As_Last (Link.From, Last_From);
            Share (Link.To);
            Share_As_Last (Link.Origin, Last_Origin);
         end;
      end loop;
   end Share_Names;

   --  The relations found by reading a file's uses of names -- read again
   --  when what they name may have changed, and kept in buckets where a
   --  graph is past one record. The rest are what the file declares.
   function Is_Reference (Kind : Relation_Kind) return Boolean
   is (Kind in References | Calls);

   procedure Add_Relation (Into : in out Graph; Item : Relation) is
      Made : Relation := Item;
   begin
      if Made.Origin = Null_Unbounded_String then
         Made.Origin := Into.Reading;
      end if;
      Into.Relations.Append (Made);
   end Add_Relation;

   function File_Count (From : Graph) return Natural
   is (Natural (From.Files.Length));

   function File_At (From : Graph; Index : Positive) return File_Entry
   is (From.Files (Index));

   function Unread_Count (From : Graph) return Natural
   is (Natural (From.Unread.Length));

   function Unread_At (From : Graph; Index : Positive) return String
   is (From.Unread (Index));

   function Unread_Paths (From : Graph) return Name_Lists.Vector is
      Result : Name_Lists.Vector;
   begin
      for Said of From.Unread loop
         declare
            Colon : constant Natural := Ada.Strings.Fixed.Index (Said, ": ");
         begin
            if Colon > Said'First
              and then Said (Colon + 2 .. Said'Last) /= Link_Not_Followed
            then
               Result.Append (Said (Said'First .. Colon - 1));
            end if;
         end;
      end loop;
      return Result;
   end Unread_Paths;

   function Binary_Files (From : Graph) return Name_Lists.Vector
   is (From.Skipped);

   function Symbol_Count (From : Graph) return Natural
   is (Natural (From.Symbols.Length));

   function Symbol_At (From : Graph; Index : Positive) return Symbol
   is (From.Symbols (Index));

   function Relation_Count (From : Graph) return Natural
   is (Natural (From.Relations.Length));

   function Relation_At (From : Graph; Index : Positive) return Relation
   is (From.Relations (Index));

   -----------------------
   -- Graph_Fingerprint --
   -----------------------

   function Graph_Fingerprint (From : Graph) return String is
      Text : Unbounded_String;
   begin
      for Item of From.Files loop
         Append (Text, Item.Path & Tab & Item.Fingerprint & ASCII.LF);
      end loop;
      --  And what could not be read: a view missing a file is another
      --  state than a whole one, though what it read is the same.
      for Said of From.Unread loop
         Append (Text, "unread" & Tab & Said & ASCII.LF);
      end loop;
      --  And the files of bytes, by their stamps: a binary fixture or a
      --  golden file replaced left the revision as it was, and evidence
      --  for the tree before was taken for the tree after.
      for Line of From.Skipped loop
         Append (Text, "bytes" & Tab & Line & ASCII.LF);
      end loop;
      return Fingerprint (To_String (Text));
   end Graph_Fingerprint;

   -----------------
   -- Language_Of --
   -----------------

   function Language_Of (Path : String) return String is
      Name : constant String := Lower (Path);

      function Ends (Suffix : String) return Boolean
      is (Name'Length > Suffix'Length
          and then Name (Name'Last - Suffix'Length + 1 .. Name'Last) = Suffix);
   begin
      if Ends (".ads") or else Ends (".adb") or else Ends (".ada") then
         return "Ada";
      elsif Ends (".gpr") then
         return "GPR";
      elsif Ends (".c") or else Ends (".h") then
         return "C";
      elsif Ends (".cpp") or else Ends (".hpp") or else Ends (".cc") or else Ends (".hh")
        or else Ends (".cxx") or else Ends (".hxx")
      then
         return "C++";
      elsif Ends (".rs") then
         return "Rust";
      elsif Ends (".py") then
         return "Python";
      elsif Ends (".go") then
         return "Go";
      elsif Ends ("/go.mod") or else Ends ("/go.sum") or else Name in "go.mod" | "go.sum" then
         return "Go module";
      elsif Ends (".ts") or else Ends (".tsx") then
         return "TypeScript";
      elsif Ends (".js") or else Ends (".jsx") or else Ends (".mjs") then
         return "JavaScript";
      elsif Ends (".java") then
         return "Java";
      elsif Ends (".md") then
         return "Markdown";
      elsif Ends (".adoc") or else Ends (".asciidoc") then
         return "AsciiDoc";
      elsif Ends (".rst") then
         return "reStructuredText";
      elsif Ends (".toml") then
         return "TOML";
      elsif Ends (".json") then
         return "JSON";
      elsif Ends (".sh") then
         return "Shell";
      elsif Ends (".txt") then
         return "Text";
      end if;
      return "";
   end Language_Of;

   -------------
   -- Role_Of --
   -------------

   -------------------
   -- Default_Roots --
   -------------------

   function Default_Roots return Roots
   is (Skip          => Split ("obj bin alire node_modules target build _build *.ali/ *.o/ *.a/ *.so/"),
       Tests         => Split ("test tests testsuite *_test."),
       Documentation => Split ("doc docs"),
       Generated     => Split ("generated *.pb.go *_pb2.py *.pb.h *.pb.cc"));

   --------------
   -- Roots_Of --
   --------------

   -------------------
   -- Relative_Path --
   -------------------

   function Relative_Path (Project, Path : String) return String is
      Base : constant String :=
        (if Project'Length > 1 and then Project (Project'Last) = '/'
         then Project (Project'First .. Project'Last - 1) else Project);
      Rest : constant String :=
        (if Path = Base then ""
         elsif Path'Length > Base'Length and then Path (Path'First .. Path'First + Base'Length) = Base & "/"
         then Path (Path'First + Base'Length + 1 .. Path'Last)
         else Path);
      Kept  : Name_Lists.Vector;
      Start : Positive := Rest'First;
      Out_Of : Boolean := False;
   begin
      if Rest'Length > 0 and then Rest (Rest'First) = '/' then
         return Path;
      end if;
      for Index in Rest'First .. Rest'Last + 1 loop
         if Index > Rest'Last or else Rest (Index) = '/' then
            declare
               Part : constant String := Rest (Start .. Index - 1);
            begin
               if Part = "" or else Part = "." then
                  null;
               elsif Part = ".." then
                  if Kept.Is_Empty then
                     Out_Of := True;
                  else
                     Kept.Delete_Last;
                  end if;
               else
                  Kept.Append (Part);
               end if;
            end;
            Start := Index + 1;
         end if;
      end loop;
      if Out_Of then
         return Path;
      end if;
      declare
         Joined : Unbounded_String;
      begin
         for Part of Kept loop
            Append (Joined, (if Joined = Null_Unbounded_String then "" else "/") & Part);
         end loop;
         return To_String (Joined)
           & (if Kept.Is_Empty or else Rest'Length = 0 or else Rest (Rest'Last) /= '/' then "" else "/");
      end;
   end Relative_Path;

   ---------------------
   -- Component_Roots --
   ---------------------

   function Component_Roots (Item : Stores.Store; Component : String) return Name_Lists.Vector
   is (Component_Roots (Configurations.Required (Item), Component));

   function Component_Roots (Config : Records.Item; Component : String) return Name_Lists.Vector is
      Result : Name_Lists.Vector;

      --  Whether the word from From on says NAME=VALUE: the roots end
      --  there; any other word after a space or a comma is one more root.
      function Setting_At (Text : String; From : Positive) return Boolean is
      begin
         for Index in From .. Text'Last loop
            exit when Text (Index) in '|' | ',' | ' ';
            if Text (Index) = '=' then
               return True;
            end if;
         end loop;
         return False;
      end Setting_At;
   begin
      declare
         Text  : constant String := Records.Get (Config, "map.component." & Component);
         Mark  : constant Natural := Ada.Strings.Fixed.Index (Text, "roots=");
         Start : Natural;
      begin
         if Mark = 0 then
            return Result;
         end if;
         Start := Mark + 6;
         for Index in Mark + 6 .. Text'Last + 1 loop
            if Index > Text'Last or else Text (Index) in '|' | ',' | ' ' then
               --  packages/web/ is packages/web: a directory, however written.
               if Index - 1 > Start and then Text (Index - 1) = '/' then
                  Result.Append (Text (Start .. Index - 2));
               elsif Index > Start then
                  Result.Append (Text (Start .. Index - 1));
               end if;
               Start := Index + 1;
               exit when Index <= Text'Last and then Text (Index) in ',' | ' '
                 and then Setting_At (Text, Index + 1);
            end if;
         end loop;
      end;
      return Result;
   end Component_Roots;

   ------------------
   -- In_Component --
   ------------------

   function In_Component (Item : Stores.Store; Component, Path : String) return Boolean
   is (In_Component (Configurations.Required (Item), Component, Path));

   function In_Component (Config : Records.Item; Component, Path : String) return Boolean is
      function Clean (Text : String) return String is
         Result : String := Text;
         Last   : Natural := Result'Last;
      begin
         for C of Result loop
            if C = '\' then
               C := '/';
            end if;
         end loop;
         while Last >= Result'First and then Result (Last) = '/' loop
            Last := Last - 1;
         end loop;
         return (if Last >= Result'First and then Result (Result'First .. Result'First + 1 - 1) = "."
                   and then Last > Result'First and then Result (Result'First + 1) = '/'
                 then Result (Result'First + 2 .. Last) else Result (Result'First .. Last));
      end Clean;
      File : constant String := Clean (Path);

      --  How closely a component's roots hold the file: the length of the
      --  longest root it is under, or none.
      function Closeness (Named : String) return Integer is
         Best : Integer := -1;
      begin
         for Root of Component_Roots (Config, Named) loop
            declare
               R : constant String := Clean (Root);
            begin
               --  The project's top holds every file, least closely.
               if R in "." | "" then
                  Best := Integer'Max (Best, 0);
               elsif File = R or else (File'Length > R'Length
                                    and then File (File'First .. File'First + R'Length - 1) = R
                                    and then File (File'First + R'Length) = '/')
               then
                  Best := Integer'Max (Best, R'Length);
               end if;
            end;
         end loop;
         return Best;
      end Closeness;

      Mine : constant Integer := Closeness (Component);
   begin
      if Mine < 0 then
         return False;
      end if;
      --  Where roots overlap, the file is the component's whose root holds
      --  it most closely: src/proc is proc's, not src's.
      for Index in 1 .. Records.Field_Count (Config) loop
         declare
            Field : constant String := Records.Field_Name (Config, Index);
         begin
            if Field'Length > 14 and then Field (Field'First .. Field'First + 13) = "map.component."
              and then Field (Field'First + 14 .. Field'Last) /= Component
              and then Closeness (Field (Field'First + 14 .. Field'Last)) > Mine
            then
               return False;
            end if;
         end;
      end loop;
      return True;
   end In_Component;

   function Roots_Of (Item : Stores.Store) return Roots is
      Result : Roots := Default_Roots;
      Config : Records.Item;

      procedure Take (Name : String; Into : in out Name_Lists.Vector) is
         Given : constant Name_Lists.Vector :=
           Split (Records.Get (Config, "set.repository." & Name));
      begin
         if not Given.Is_Empty then
            Into := Given;
         end if;
      end Take;
   begin
      Config := Configurations.Required (Item);
      Take ("skip", Result.Skip);
      Take ("tests", Result.Tests);
      Take ("documentation", Result.Documentation);
      Take ("generated", Result.Generated);
      return Result;
   end Roots_Of;

   function Named_By (Listed : Name_Lists.Vector; Path : String) return Boolean;

   -----------------
   -- Under_Roots --
   -----------------

   function Under_Roots (Listed : Name_Lists.Vector; Path : String) return Boolean
   is (Named_By (Listed, Path));

   --  Whether a path within the project is one a root names.
   function Named_By (Listed : Name_Lists.Vector; Path : String) return Boolean is
      Name : constant String := "/" & Lower (Path) & "/";
   begin
      for Root of Listed loop
         declare
            Given : constant String := Lower (Root);
         begin
            if Given'Length > 1 and then Given (Given'First) = '*' then
               if Ada.Strings.Fixed.Index (Name, Given (Given'First + 1 .. Given'Last)) > 0 then
                  return True;
               end if;
            elsif Given /= ""
              and then Ada.Strings.Fixed.Index (Name, "/" & Trim_Slashes (Given) & "/") > 0
            then
               return True;
            end if;
         end;
      end loop;
      return False;
   end Named_By;

   function Role_Of (Path : String; Within : Roots := Default_Roots) return File_Role is
      Name : constant String := "/" & Lower (Path);

      function Has (Part : String) return Boolean
      is (Ada.Strings.Fixed.Index (Name, Part) > 0);

      Language : constant String := Language_Of (Path);
   begin
      if Named_By (Within.Generated, Path) then
         return Generated;
      elsif Named_By (Within.Tests, Path) then
         return Test;
      elsif Language in "Markdown" | "AsciiDoc" | "reStructuredText" or else Named_By (Within.Documentation, Path)
      then
         return Documentation;
      elsif Language in "GPR" | "TOML" | "JSON" | "Shell" | "Go module"
        or else Has ("/makefile") or else Has ("/cmakelists.txt")
      then
         return Build;
      elsif Language /= "" and then Language /= "Text" then
         return Source;
      end if;
      return Other;
   end Role_Of;

   --------------------
   -- Says_Generated --
   --------------------

   function Says_Generated (Text : String) return Boolean is
      Lines : Natural := 0;
      Stop  : Natural := Text'First - 1;
   begin
      while Stop < Text'Last and then Lines < 5 loop
         Stop := Stop + 1;
         if Text (Stop) = ASCII.LF then
            Lines := Lines + 1;
         end if;
      end loop;
      declare
         Head : constant String := Lower (Text (Text'First .. Stop));

         function Has (Part : String) return Boolean
         is (Ada.Strings.Fixed.Index (Head, Part) > 0);
      begin
         return Has ("@generated") or else Has ("automatically generated")
           or else (Has ("generated") and then (Has ("do not edit") or else Has ("don't edit")));
      end;
   end Says_Generated;

   ---------------------------------------------------------------------------
   --  The generic adapter.
   ---------------------------------------------------------------------------

   overriding function Language (Self : Generic_Adapter) return String
   is ("generic");

   overriding procedure Read
     (Self : Generic_Adapter;
      Path : String;
      Text : String;
      Into : in out Graph) is
   begin
      --  The file is in the graph already; nothing in it is read.
      null;
   end Read;

   ---------------------------------------------------------------------------
   --  Reading Ada.
   ---------------------------------------------------------------------------

   type Token_Kind is (Word, Symbol_Mark, Text_Literal);

   type Token is record
      Kind : Token_Kind := Word;
      Text : Unbounded_String;
      Line : Positive := 1;
   end record;

   package Token_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Token);

   --  Where each word of a file is, by its lower-case spelling: a symbol's
   --  uses are looked up rather than every token walked for every symbol.
   package Place_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Positive);
   package Word_Places is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type => String, Element_Type => Place_Vectors.Vector,
      Hash => Ada.Strings.Hash, Equivalent_Keys => "=",
      "=" => Place_Vectors."=");
   package Name_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type => String, Element_Type => Name_Lists.Vector,
      Hash => Ada.Strings.Hash, Equivalent_Keys => "=",
      "=" => Name_Lists."=");
   package Stamp_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type => String, Element_Type => String, Hash => Ada.Strings.Hash, Equivalent_Keys => "=");

   --  Add a place under a key.
   procedure Add_Place (Into : in out Word_Places.Map; Key : String; Place : Positive) is
      Position : constant Word_Places.Cursor := Into.Find (Key);
   begin
      if Word_Places.Has_Element (Position) then
         Into.Reference (Position).Append (Place);
      else
         Into.Insert (Key, Place_Vectors.To_Vector (Place, 1));
      end if;
   end Add_Place;

   --  Add a name under a key.
   procedure Add_Name (Into : in out Name_Maps.Map; Key : String; Name : String) is
      Position : constant Name_Maps.Cursor := Into.Find (Key);
   begin
      if Name_Maps.Has_Element (Position) then
         Into.Reference (Position).Append (Name);
      else
         Into.Insert (Key, Name_Lists.To_Vector (Name, 1));
      end if;
   end Add_Name;

   package Name_Sets is new Ada.Containers.Indefinite_Hashed_Sets
     (Element_Type => String, Hash => Ada.Strings.Hash, Equivalent_Elements => "=");

   --  The tokens of Ada text: words, and each other mark on its own, with
   --  comments left out and literals kept whole.
   function Tokens_Of (Text : String) return Token_Vectors.Vector is
      Result : Token_Vectors.Vector;
      Index  : Natural := Text'First;
      Line   : Positive := 1;
   begin
      while Index <= Text'Last loop
         declare
            Char : constant Character := Text (Index);
         begin
            if Char = ASCII.LF then
               Line := Line + 1;
               Index := Index + 1;
            elsif Char = '-' and then Index < Text'Last
              and then Text (Index + 1) = '-'
            then
               while Index <= Text'Last and then Text (Index) /= ASCII.LF loop
                  Index := Index + 1;
               end loop;
            elsif Char = '"' then
               declare
                  Start : constant Positive := Index;
               begin
                  Index := Index + 1;
                  loop
                     exit when Index > Text'Last or else Text (Index) = ASCII.LF;
                     if Text (Index) = '"' then
                        if Index < Text'Last and then Text (Index + 1) = '"' then
                           Index := Index + 2;
                        else
                           Index := Index + 1;
                           exit;
                        end if;
                     else
                        Index := Index + 1;
                     end if;
                  end loop;
                  Result.Append
                    (Token'(Text_Literal,
                      To_Unbounded_String (Text (Start .. Index - 1)), Line));
               end;
            elsif Char = ''' and then Index + 2 <= Text'Last
              and then Text (Index + 2) = '''
              and then (Result.Is_Empty
                        or else Result.Last_Element.Kind /= Word)
            then
               --  A character literal; after a word the tick is an
               --  attribute's.
               Result.Append
                 (Token'(Text_Literal,
                   To_Unbounded_String (Text (Index .. Index + 2)), Line));
               Index := Index + 3;
            elsif Ada.Characters.Handling.Is_Letter (Char)
              or else Character'Pos (Char) >= 128
            then
               declare
                  Start : constant Positive := Index;
               begin
                  while Index <= Text'Last
                    and then (Ada.Characters.Handling.Is_Alphanumeric
                                (Text (Index))
                              or else Text (Index) = '_'
                              or else Character'Pos (Text (Index)) >= 128)
                  loop
                     Index := Index + 1;
                  end loop;
                  Result.Append
                    (Token'(Word, To_Unbounded_String (Text (Start .. Index - 1)),
                      Line));
               end;
            elsif Char in ' ' | ASCII.HT | ASCII.CR | ASCII.FF | ASCII.VT then
               Index := Index + 1;
            elsif Ada.Characters.Handling.Is_Digit (Char) then
               while Index <= Text'Last
                 and then (Ada.Characters.Handling.Is_Alphanumeric (Text (Index))
                           or else Text (Index) in '_' | '.' | '#')
               loop
                  Index := Index + 1;
               end loop;
            else
               Result.Append (Token'(Symbol_Mark, To_Unbounded_String ([1 => Char]), Line));
               Index := Index + 1;
            end if;
         end;
      end loop;
      return Result;
   end Tokens_Of;

   function Is_Word (Item : Token; Word_Text : String) return Boolean
   is (Item.Kind = Word and then Lower (To_String (Item.Text)) = Word_Text);

   function Is_Mark (Item : Token; Mark : Character) return Boolean
   is (Item.Kind = Symbol_Mark and then To_String (Item.Text) = [1 => Mark]);

   --  A dotted name starting at a token, and the token after it.
   procedure Name_At
     (Tokens : Token_Vectors.Vector;
      Start  : Positive;
      Name   : out Unbounded_String;
      Next   : out Positive)
   is
      Index : Positive := Start;
   begin
      Name := Null_Unbounded_String;
      Next := Start;
      if Start > Natural (Tokens.Length) or else Tokens (Start).Kind /= Word then
         return;
      end if;
      Name := Tokens (Index).Text;
      Index := Index + 1;
      while Index + 1 <= Natural (Tokens.Length)
        and then Is_Mark (Tokens (Index), '.')
        and then Tokens (Index + 1).Kind = Word
      loop
         Append (Name, "." & Tokens (Index + 1).Text);
         Index := Index + 2;
      end loop;
      Next := Index;
   end Name_At;

   --  The unit a file holds, as its first declaration names it.
   function Unit_Of (Tokens : Token_Vectors.Vector) return String is
      Name : Unbounded_String;
      Next : Positive;
   begin
      for Index in 1 .. Natural (Tokens.Length) loop
         --  Not a generic's formal subprogram or package: with function
         --  Hash (...) names no unit.
         if (Is_Word (Tokens (Index), "package") or else Is_Word (Tokens (Index), "procedure")
             or else Is_Word (Tokens (Index), "function"))
           and then not (Index > 1 and then Is_Word (Tokens (Index - 1), "with"))
         then
            declare
               At_Name : constant Positive :=
                 (if Index < Natural (Tokens.Length)
                    and then Is_Word (Tokens (Index + 1), "body")
                  then Index + 2 else Index + 1);
            begin
               Name_At (Tokens, At_Name, Name, Next);
               return To_String (Name);
            end;
         elsif Is_Word (Tokens (Index), "separate") then
            --  A subunit is part of its parent.
            Name_At (Tokens, Index + 2, Name, Next);
            return To_String (Name);
         end if;
      end loop;
      return "";
   end Unit_Of;

   overriding function Language (Self : Ada_Adapter) return String
   is ("Ada");

   overriding procedure Read
     (Self : Ada_Adapter;
      Path : String;
      Text : String;
      Into : in out Graph)
   is
      Tokens : constant Token_Vectors.Vector := Tokens_Of (Text);
      Count  : constant Natural := Natural (Tokens.Length);
      Unit   : constant String := Unit_Of (Tokens);
      Is_Body : constant Boolean :=
        Lower (Path) (Path'Last - 3 .. Path'Last) = ".adb"
        or else (for some Index in 1 .. Count - 1 =>
                   Is_Word (Tokens (Index), "package")
                   and then Is_Word (Tokens (Index + 1), "body"));
      Index  : Positive := 1;
      Depth  : Integer := 0;
      Name   : Unbounded_String;
      Next   : Positive;
      Header_Seen : Boolean := False;
   begin
      if Unit = "" then
         return;
      end if;

      Add_Relation
        (Into,
         (Kind => Contains, From => To_Unbounded_String (Path),
          To => To_Unbounded_String (Unit), Source => Explicit, Sure => Certain,
          Where => Null_Unbounded_String, Origin => <>));

      if Is_Body then
         Add_Relation
           (Into,
            (Kind => Implements, From => To_Unbounded_String (Path),
             To => To_Unbounded_String (Unit), Source => Explicit,
             Sure => Certain, Where => Null_Unbounded_String, Origin => <>));
      end if;

      --  A child unit sees its parent's declarations without withing it:
      --  it depends on its parent as if it did.
      declare
         Dot : constant Natural := Ada.Strings.Fixed.Index (Unit, ".", Ada.Strings.Backward);
      begin
         if Dot > Unit'First then
            Add_Relation
              (Into,
               (Kind => Depends_On, From => To_Unbounded_String (Unit),
                To => To_Unbounded_String (Unit (Unit'First .. Dot - 1)), Source => Explicit,
                Sure => Certain, Where => Null_Unbounded_String, Origin => <>));
         end if;
      end;

      --  The context clause: what this unit withs.
      while Index <= Count loop
         exit when Is_Word (Tokens (Index), "package")
           or else Is_Word (Tokens (Index), "procedure")
           or else Is_Word (Tokens (Index), "function")
           or else Is_Word (Tokens (Index), "generic")
           or else Is_Word (Tokens (Index), "separate");
         if Is_Word (Tokens (Index), "with") then
            Index := Index + 1;
            loop
               Name_At (Tokens, Index, Name, Next);
               exit when Name = Null_Unbounded_String;
               Add_Relation
                 (Into,
                  (Kind => Depends_On, From => To_Unbounded_String (Unit),
                   To => Name, Source => Explicit, Sure => Certain,
                   Where => To_Unbounded_String
                              (Path & ":" & Image (Tokens (Index).Line)), Origin => <>));
               Index := Next;
               exit when Index > Count or else not Is_Mark (Tokens (Index), ',');
               Index := Index + 1;
            end loop;
         else
            Index := Index + 1;
         end if;
      end loop;

      --  What is made from what, anywhere in the unit: instantiations,
      --  derivations and the interfaces they take on, and overriding.
      for At_Index in Index .. Count loop
         declare
            Here : constant Token := Tokens (At_Index);
         begin
            if Here.Kind = Word
              and then Lower (To_String (Here.Text)) in "package" | "procedure" | "function"
              and then At_Index + 4 <= Count
              and then Tokens (At_Index + 1).Kind = Word
              and then Is_Word (Tokens (At_Index + 2), "is")
              and then Is_Word (Tokens (At_Index + 3), "new")
            then
               declare
                  Made : Unbounded_String;
                  Past : Positive;
               begin
                  Name_At (Tokens, At_Index + 4, Made, Past);
                  if Made /= Null_Unbounded_String then
                     Add_Relation
                       (Into,
                        (Kind => Instantiates,
                         From => To_Unbounded_String
                                   (Unit & "." & To_String (Tokens (At_Index + 1).Text)),
                         --  Said in the text; what the name names is not
                         --  resolved -- a use clause or a renaming could
                         --  make it another -- so probable.
                         To => Made, Source => Explicit, Sure => Probable,
                         Where => To_Unbounded_String (Path & ":" & Image (Here.Line)), Origin => <>));
                  end if;
               end;
            elsif Is_Word (Here, "type") and then At_Index + 1 <= Count
              and then Tokens (At_Index + 1).Kind = Word
            then
               declare
                  Typed : constant String :=
                    Unit & "." & To_String (Tokens (At_Index + 1).Text);
                  Ahead : Positive := At_Index + 2;
                  Seen_Is : Boolean := False;
               begin
                  while Ahead <= Count and then not Is_Mark (Tokens (Ahead), ';') loop
                     if Is_Word (Tokens (Ahead), "is") then
                        Seen_Is := True;
                     elsif Seen_Is
                       and then (Is_Word (Tokens (Ahead), "new")
                                 or else Is_Word (Tokens (Ahead), "and"))
                     then
                        declare
                           Other : Unbounded_String;
                           Past  : Positive;
                        begin
                           Name_At (Tokens, Ahead + 1, Other, Past);
                           if Other /= Null_Unbounded_String
                             and then Lower (To_String (Other)) not in "with" | "record"
                           then
                              Add_Relation
                                (Into,
                                 (Kind => (if Is_Word (Tokens (Ahead), "new") then Extends
                                           else Implements_Interface),
                                  From => To_Unbounded_String (Typed), To => Other,
                                  Source => Explicit, Sure => Probable,
                                  Where => To_Unbounded_String
                                             (Path & ":" & Image (Tokens (Ahead).Line)), Origin => <>));
                           end if;
                        end;
                     elsif Seen_Is and then Is_Word (Tokens (Ahead), "record") then
                        exit;
                     end if;
                     Ahead := Ahead + 1;
                  end loop;
               end;
            elsif Is_Word (Here, "overriding") and then At_Index + 2 <= Count
              and then Tokens (At_Index + 2).Kind = Word
            then
               Add_Relation
                 (Into,
                  (Kind => Overrides,
                   From => To_Unbounded_String
                             (Unit & "." & To_String (Tokens (At_Index + 2).Text)),
                   --  That it overrides is said; which ancestor's
                   --  operation it overrides is not worked out, so the
                   --  name alone, and uncertain.
                   To => Tokens (At_Index + 2).Text, Source => Explicit, Sure => Uncertain,
                   Where => To_Unbounded_String (Path & ":" & Image (Here.Line)), Origin => <>));
            end if;
         end;
      end loop;

      --  The unit itself is a symbol, and in a spec so is everything it
      --  declares at its outer level.
      if not Is_Body or else not (for some Index in 1 .. Count =>
                                     Is_Word (Tokens (Index), "package"))
      then
         Add_Symbol
           (Into,
            (Name => To_Unbounded_String (Unit),
             Kind => To_Unbounded_String
                       (if Index <= Count then Lower (To_String (Tokens (Index).Text))
                        else "unit"),
             Path => To_Unbounded_String (Path),
             Line => (if Index <= Count then Tokens (Index).Line else 1)));
      end if;

      --  In a body, each subprogram the unit's outer level gives a body:
      --  a place it is declared too, so /sym names the body beside the
      --  spec. Nesting is followed by what opens and closes a body -- a
      --  header ending in is, declare, a begin that is no header's own --
      --  a block of its own -- and end other than end if, loop, case,
      --  record, select or return.
      if Is_Body then
         declare
            Level : Natural := 0;
            Where : Positive := Index;

            --  For each level open, whether its begin has been seen: a
            --  begin past it opens a block, one level more.
            Begun : array (1 .. 200) of Boolean := [others => True];

            --  Where a header from At_Token ends: its is, or its ;, at no
            --  depth of brackets; 0 at neither.
            function Header_End (At_Token : Positive) return Natural is
               Brackets : Integer := 0;
            begin
               for Ahead in At_Token .. Count loop
                  if Is_Mark (Tokens (Ahead), '(') then
                     Brackets := Brackets + 1;
                  elsif Is_Mark (Tokens (Ahead), ')') then
                     Brackets := Brackets - 1;
                  elsif Brackets = 0 and then (Is_Mark (Tokens (Ahead), ';') or else Is_Word (Tokens (Ahead), "is"))
                  then
                     return Ahead;
                  end if;
               end loop;
               return 0;
            end Header_End;
         begin
            while Where <= Count loop
               declare
                  Spelled : constant String :=
                    (if Tokens (Where).Kind = Word then Lower (To_String (Tokens (Where).Text)) else "");
               begin
                  if Spelled in "procedure" | "function" | "package" | "task" | "protected" | "entry"
                    and then not (Where > 1 and then Is_Word (Tokens (Where - 1), "access"))
                  then
                     declare
                        Stop : constant Natural := Header_End (Where + 1);
                        At_Name : Positive := Where + 1;
                     begin
                        if At_Name <= Count and then Is_Word (Tokens (At_Name), "body") then
                           At_Name := At_Name + 1;
                        end if;
                        if Stop > 0 and then Is_Word (Tokens (Stop), "is")
                          and then Stop < Count
                          and then not Is_Word (Tokens (Stop + 1), "new")
                          and then not Is_Word (Tokens (Stop + 1), "null")
                          and then not Is_Word (Tokens (Stop + 1), "abstract")
                          and then not Is_Word (Tokens (Stop + 1), "separate")
                          and then not Is_Mark (Tokens (Stop + 1), '(')
                        then
                           if Level = 1 and then Spelled in "procedure" | "function"
                             and then At_Name <= Count and then Tokens (At_Name).Kind = Word
                           then
                              Add_Symbol
                                (Into,
                                 (Name => To_Unbounded_String (Unit & "." & To_String (Tokens (At_Name).Text)),
                                  Kind => To_Unbounded_String ("body"),
                                  Path => To_Unbounded_String (Path),
                                  Line => Tokens (At_Name).Line));
                           end if;
                           Level := Level + 1;
                           if Level in Begun'Range then
                              Begun (Level) := False;
                           end if;
                           Where := Stop;
                        elsif Stop > 0 then
                           Where := Stop;
                        end if;
                     end;
                  elsif Spelled = "declare" then
                     Level := Level + 1;
                     if Level in Begun'Range then
                        Begun (Level) := False;
                     end if;
                  elsif Spelled = "begin" then
                     if Level in Begun'Range and then not Begun (Level) then
                        Begun (Level) := True;
                     else
                        Level := Level + 1;
                        if Level in Begun'Range then
                           Begun (Level) := True;
                        end if;
                     end if;
                  elsif Spelled = "end" then
                     if not (Where < Count
                             and then (Is_Word (Tokens (Where + 1), "if") or else Is_Word (Tokens (Where + 1), "loop")
                                       or else Is_Word (Tokens (Where + 1), "case")
                                       or else Is_Word (Tokens (Where + 1), "record")
                                       or else Is_Word (Tokens (Where + 1), "select")
                                       or else Is_Word (Tokens (Where + 1), "return")))
                       and then Level > 0
                     then
                        Level := Level - 1;
                     end if;
                  end if;
               end;
               Where := Where + 1;
            end loop;
         end;
         return;
      end if;

      while Index <= Count loop
         declare
            Here : constant Token := Tokens (Index);
            Spelled : constant String :=
              (if Here.Kind = Word then Lower (To_String (Here.Text)) else "");
         begin
            if Spelled = "record" and then not
              (Index > 1 and then Is_Word (Tokens (Index - 1), "null"))
            then
               Depth := Depth + 1;
            elsif Spelled = "end" then
               if Index < Count and then Is_Word (Tokens (Index + 1), "record") then
                  Depth := Depth - 1;
                  Index := Index + 1;
               elsif Depth > 0 then
                  Depth := Depth - 1;
               end if;
            --  Not an access-to-subprogram type's profile: access function
            --  return Boolean declares no function called return.
            elsif Depth = 1
              and then Spelled in "procedure" | "function" | "type" | "subtype"
                             | "package" | "task" | "protected" | "entry"
              and then not (Index > 1 and then (Is_Word (Tokens (Index - 1), "access")
                                                or else Is_Word (Tokens (Index - 1), "protected")))
            then
               declare
                  At_Name : Positive := Index + 1;
               begin
                  if At_Name <= Count
                    and then (Is_Word (Tokens (At_Name), "type")
                              or else Is_Word (Tokens (At_Name), "body"))
                  then
                     At_Name := At_Name + 1;
                  end if;
                  if At_Name <= Count and then Tokens (At_Name).Kind = Word then
                     Add_Symbol
                       (Into,
                        (Name => To_Unbounded_String
                                   (Unit & "." & To_String (Tokens (At_Name).Text)),
                         Kind => To_Unbounded_String (Spelled),
                         Path => To_Unbounded_String (Path),
                         Line => Tokens (At_Name).Line));
                  end if;

                  --  type Kind is (Number, Plus, ...): each literal a name
                  --  of the unit's, as the type is.
                  if Spelled = "type" and then At_Name + 2 <= Count
                    and then Is_Word (Tokens (At_Name + 1), "is")
                    and then Is_Mark (Tokens (At_Name + 2), '(')
                  then
                     for Ahead in At_Name + 3 .. Count loop
                        exit when Is_Mark (Tokens (Ahead), ')') or else Is_Mark (Tokens (Ahead), ';');
                        if Tokens (Ahead).Kind = Word
                          and then (Is_Mark (Tokens (Ahead - 1), '(') or else Is_Mark (Tokens (Ahead - 1), ','))
                        then
                           Add_Symbol
                             (Into,
                              (Name => To_Unbounded_String (Unit & "." & To_String (Tokens (Ahead).Text)),
                               Kind => To_Unbounded_String ("literal"),
                               Path => To_Unbounded_String (Path),
                               Line => Tokens (Ahead).Line));
                        end if;
                     end loop;
                  end if;

                  --  A nested package, task or protected unit opens a
                  --  scope of its own whose declarations are not the
                  --  unit's.
                  if Spelled in "package" | "task" | "protected" then
                     for Ahead in At_Name .. Count loop
                        exit when Is_Mark (Tokens (Ahead), ';');
                        if Is_Word (Tokens (Ahead), "is") then
                           if Ahead < Count
                             and then not Is_Word (Tokens (Ahead + 1), "new")
                             and then not Is_Word (Tokens (Ahead + 1), "separate")
                           then
                              Depth := Depth + 1;
                           end if;
                           exit;
                        end if;
                     end loop;
                  end if;
               end;
            elsif Depth = 1 and then Here.Kind = Word and then Index + 2 <= Count
              and then Is_Mark (Tokens (Index + 1), ':')
              and then (Is_Word (Tokens (Index + 2), "constant")
                        or else Is_Word (Tokens (Index + 2), "exception"))
            then
               Add_Symbol
                 (Into,
                  (Name => To_Unbounded_String
                             (Unit & "." & To_String (Here.Text)),
                   Kind => To_Unbounded_String
                             (Lower (To_String (Tokens (Index + 2).Text))),
                   Path => To_Unbounded_String (Path),
                   Line => Here.Line));
            elsif Depth = 0 and then Spelled in "package" | "procedure" | "function"
              and then not (Index > 1 and then Is_Word (Tokens (Index - 1), "with"))
            then
               --  The unit's own header, past a generic's formal part.
               Header_Seen := True;
            elsif Depth = 0 and then Spelled = "is" and then Header_Seen then
               --  The unit's own declarations begin.
               Depth := 1;
            end if;
         end;
         Index := Index + 1;
      end loop;
   end Read;

   --  The last part of a dotted name.
   function Last_Part (Name : String) return String is
      Dot : constant Natural := Ada.Strings.Fixed.Index (Name, ".", Ada.Strings.Backward);
   begin
      return (if Dot = 0 then Name else Name (Dot + 1 .. Name'Last));
   end Last_Part;

   --------------
   -- Catch_Up --
   --------------

   procedure Catch_Up (Into : in out Graph) is
      procedure Note (Map : in out Places_By_Name.Map; Key : String; Place : Positive) is
      begin
         if not Map.Contains (Key) then
            Map.Insert (Key, Place_Lists.Empty_Vector);
         end if;
         Map.Reference (Key).Append (Place);
      end Note;
   begin
      --  Fewer than it looked at: another graph's, begun again.
      if Into.Depends_Seen > Natural (Into.Relations.Length) then
         Into.Depends_By_Unit.Clear;
         Into.Depends_Seen := 0;
      end if;
      for Place in Into.Depends_Seen + 1 .. Natural (Into.Relations.Length) loop
         if Into.Relations (Place).Kind = Depends_On then
            Note (Into.Depends_By_Unit, To_String (Into.Relations (Place).From), Place);
         end if;
      end loop;
      Into.Depends_Seen := Natural (Into.Relations.Length);
      if Into.Symbols_Seen > Natural (Into.Symbols.Length) then
         Into.Symbols_By_Last.Clear;
         Into.Symbols_Seen := 0;
      end if;
      for Place in Into.Symbols_Seen + 1 .. Natural (Into.Symbols.Length) loop
         Note (Into.Symbols_By_Last, Lower (Last_Part (To_String (Into.Symbols (Place).Name))), Place);
      end loop;
      Into.Symbols_Seen := Natural (Into.Symbols.Length);
   end Catch_Up;

   --  The references a file makes to the symbols of the units it withs
   --  and its own: every word that is such a symbol's last name. Read out
   --  of Known, which is only read -- its indexes caught up before -- and
   --  put down in Made, so that several files' are found at once: see
   --  Scan_Into.
   procedure Find_References
     (Path  : String;
      Text  : String;
      Known : Graph;
      Made  : in out Relation_Lists.Vector)
   is
      Tokens : constant Token_Vectors.Vector := Tokens_Of (Text);
      Unit   : constant String := Unit_Of (Tokens);
      Seen   : Name_Lists.Vector;
      Visible : Name_Sets.Set;
      Places : Word_Places.Map;
      Chosen : Place_Lists.Vector;

      --  The file's package renamings, each new name lowered to the
      --  lowered name it stands for: Rp.Find_Symbols, where package Rp
      --  renames Model_Runner.Framework.Repository, is that package's.
      Renamed : Name_Maps.Map;

      --  Renaming the name it sees the package by: whole, or as a child
      --  sees a sibling -- package Tc renames Traceability, within
      --  Model_Runner.Framework.
      function Stands_For (Short, Owner : String) return Boolean is
      begin
         if not Renamed.Contains (Lower (Short)) then
            return False;
         end if;
         declare
            Target : constant String := Renamed.Element (Lower (Short)).First_Element;
            Whole  : constant String := Lower (Owner);
         begin
            return Whole = Target
              or else (Whole'Length > Target'Length
                       and then Whole (Whole'Last - Target'Length .. Whole'Last) = "." & Target);
         end;
      end Stands_For;

      --  Whether the name at a place -- its whole dotted name -- is being
      --  declared or ended there, not used.
      --  Whether the name at a place is written whole, as its owner and
      --  itself -- Uuid.Values.Make_V7 -- a unit the file withs: no guess.
      function Spelled_Whole (At_Index : Positive; Owner : String) return Boolean is
         Spelled : Unbounded_String;
         First   : Natural := At_Index;
      begin
         while First > 2 and then Is_Mark (Tokens (First - 1), '.') and then Tokens (First - 2).Kind = Word loop
            First := First - 2;
            Spelled := (if Spelled = Null_Unbounded_String then Tokens (First).Text
                        else Tokens (First).Text & "." & Spelled);
         end loop;
         return Spelled /= Null_Unbounded_String
           and then (Lower (To_String (Spelled)) = Lower (Owner) or else Stands_For (To_String (Spelled), Owner));
      end Spelled_Whole;

      function Declaring (At_Index : Positive) return Boolean is
         First : Positive := At_Index;
      begin
         while First > 2 and then Is_Mark (Tokens (First - 1), '.')
           and then Tokens (First - 2).Kind = Word
         loop
            First := First - 2;
         end loop;
         return First > 1
           and then (Is_Word (Tokens (First - 1), "end")
                     or else Is_Word (Tokens (First - 1), "procedure")
                     or else Is_Word (Tokens (First - 1), "function")
                     or else Is_Word (Tokens (First - 1), "package")
                     or else Is_Word (Tokens (First - 1), "type")
                     or else Is_Word (Tokens (First - 1), "subtype")
                     or else Is_Word (Tokens (First - 1), "body"));
      end Declaring;
   begin
      if Unit = "" then
         return;
      end if;

      --  The units whose names this file can use: its own, what it
      --  withs, and the parents of each, which a child sees and a with of
      --  a child names too.
      Seen.Append (Unit);
      declare
         Withs : Name_Lists.Vector;
         Lines : Name_Lists.Vector;
      begin
         if Known.Depends_By_Unit.Contains (Unit) then
            for Place of Known.Depends_By_Unit.Constant_Reference (Unit) loop
               declare
                  Link : Relation renames Known.Relations (Place);
               begin
                  Seen.Append (To_String (Link.To));
                  if Ada.Strings.Fixed.Index (To_String (Link.Where), Path & ":") = 1 then
                     Withs.Append (To_String (Link.To));
                     Lines.Append (To_String (Link.Where));
                  end if;
               end;
            end loop;
         end if;

         --  Its with clause is a use of the unit it names.
         for Index in 1 .. Natural (Withs.Length) loop
            Made.Append
              (Relation'(Kind   => References,
                From   => To_Unbounded_String (Path),
                To     => To_Unbounded_String (Withs (Index)),
                Source => Explicit,
                Sure   => Certain,
                Where  => To_Unbounded_String (Lines (Index)),
                Origin => <>));
         end loop;
      end;
      for Index in 1 .. Natural (Seen.Length) loop
         declare
            Name : constant String := Seen (Index);
         begin
            for Cut in reverse Name'Range loop
               if Name (Cut) = '.' and then not Seen.Contains (Name (Name'First .. Cut - 1)) then
                  Seen.Append (Name (Name'First .. Cut - 1));
               end if;
            end loop;
         end;
      end loop;

      for Name of Seen loop
         Visible.Include (Name);
      end loop;
      for At_Index in 1 .. Natural (Tokens.Length) - 3 loop
         if Is_Word (Tokens (At_Index), "package") and then Tokens (At_Index + 1).Kind = Word
           and then Is_Word (Tokens (At_Index + 2), "renames")
         then
            declare
               Target : Unbounded_String;
               Past   : Positive;
            begin
               Name_At (Tokens, At_Index + 3, Target, Past);
               if Target /= Null_Unbounded_String then
                  Add_Name (Renamed, Lower (To_String (Tokens (At_Index + 1).Text)), Lower (To_String (Target)));
               end if;
            end;
         end if;
      end loop;
      for At_Index in 1 .. Natural (Tokens.Length) loop
         if Tokens (At_Index).Kind = Word then
            Add_Place (Places, Lower (To_String (Tokens (At_Index).Text)), At_Index);
         end if;
      end loop;

      --  The symbols whose last name the file has as a word, in the
      --  graph's order.
      declare
         package Place_Sorting is new Place_Lists.Generic_Sorting;
      begin
         for Position in Places.Iterate loop
            if Known.Symbols_By_Last.Contains (Word_Places.Key (Position)) then
               Chosen.Append (Known.Symbols_By_Last.Element (Word_Places.Key (Position)));
            end if;
         end loop;
         Place_Sorting.Sort (Chosen);
      end;
      for Place of Chosen loop
         declare
            Item  : constant Symbol := Known.Symbols (Place);
            Full  : constant String := To_String (Item.Name);
            Dot   : constant Natural :=
              Ada.Strings.Fixed.Index (Full, ".", Ada.Strings.Backward);
            Owner : constant String :=
              (if Dot = 0 then Full else Full (Full'First .. Dot - 1));
            Last  : constant String :=
              Lower (if Dot = 0 then Full else Full (Dot + 1 .. Full'Last));
            Found : constant Word_Places.Cursor := Places.Find (Last);
         begin
            if Word_Places.Has_Element (Found) and then Visible.Contains (Owner) then
               for At_Index of Places.Constant_Reference (Found) loop
                  declare
                     Here : constant Token := Tokens (At_Index);
                     Own  : constant Boolean := To_String (Item.Path) = Path;

                     --  A package is used by what it qualifies or by its
                     --  full name: a word alone that spells it is some local
                     --  name of the same spelling.
                     Qualified : constant Boolean :=
                       (At_Index < Natural (Tokens.Length)
                        and then Is_Mark (Tokens (At_Index + 1), '.'))
                       or else (At_Index > 1 and then Is_Mark (Tokens (At_Index - 1), '.'));
                  begin
                     --  A name another unit's name qualifies, as Other.Parse,
                     --  is not this unit's: a qualifier must be its owner's.
                     --  Nor is its declaration, or the end of it, a use.
                     if Here.Kind = Word and then Lower (To_String (Here.Text)) = Last
                       and then not
                         (At_Index > 2 and then Is_Mark (Tokens (At_Index - 1), '.')
                          and then Tokens (At_Index - 2).Kind = Word
                          and then Lower (To_String (Tokens (At_Index - 2).Text))
                                     /= Lower (Last_Part (Owner))
                          and then not Stands_For (To_String (Tokens (At_Index - 2).Text), Owner))
                       and then not (Own and then Here.Line = Item.Line)
                       and then not Declaring (At_Index)
                       --  An attribute, X'Image, is the language's, not a use
                       --  of something called Image.
                       and then not (At_Index > 1 and then Is_Mark (Tokens (At_Index - 1), '''))
                       and then (To_String (Item.Kind) /= "package" or else Qualified)
                     then
                        Made.Append
                          (Relation'(Kind  => References,
                            From  => To_Unbounded_String (Path),
                            To    => Item.Name,
                            Source => (if Spelled_Whole (At_Index, Owner) then Explicit else Heuristic),
                            Sure   => (if Spelled_Whole (At_Index, Owner) then Certain else Probable),
                            Where  => To_Unbounded_String
                                        (Path & ":" & Image (Here.Line)), Origin => <>));

                        --  A subprogram's name followed by its arguments or
                        --  the end of a statement is a call of it.
                        if To_String (Item.Kind) in "procedure" | "function"
                          and then At_Index < Natural (Tokens.Length)
                          and then (Is_Mark (Tokens (At_Index + 1), '(')
                                    or else Is_Mark (Tokens (At_Index + 1), ';'))
                          and then not (At_Index > 1
                                        and then (Is_Word (Tokens (At_Index - 1), "procedure")
                                                  or else Is_Word (Tokens (At_Index - 1),
                                                                   "function")
                                                  or else Is_Word (Tokens (At_Index - 1), "end")))
                        then
                           Made.Append
                             (Relation'(Kind  => Calls,
                               From  => To_Unbounded_String (Unit),
                               To    => Item.Name,
                               Source => Heuristic,
                               Sure   => Probable,
                               Where  => To_Unbounded_String
                                           (Path & ":" & Image (Here.Line)), Origin => <>));
                        end if;
                     end if;
                  end;
               end loop;
            end if;
         end;
      end loop;
   end Find_References;

   overriding procedure Read_References
     (Self : Ada_Adapter;
      Path : String;
      Text : String;
      Into : in out Graph)
   is
      Found : Relation_Lists.Vector;
   begin
      Catch_Up (Into);
      Find_References (Path, Text, Into, Found);
      for Item of Found loop
         Add_Relation (Into, Item);
      end loop;
   end Read_References;

   ---------------------------------------------------------------------------
   --  Scanning.
   ---------------------------------------------------------------------------

   --  Whether a file's adapter finds references once every file is read.
   function Reads_References (Path : String) return Boolean
   is (Language_Of (Path) in "Ada" | "C" | "C++" | "Rust" | "Python");

   --  Whether a scan leaves a file or directory out: version control's,
   --  the project state's, a tool's cache, or one the roots skip. A file
   --  whose name starts with a dot is the project's like any other --
   --  .gitignore, .github/ -- and work on it is work.
   function Skipped (Name, Relative : String; Within : Roots) return Boolean
   is (Name'Length = 0 or else Name in "." | ".." | ".git" | ".hg" | ".svn" | ".model_runner"
                                       | ".alire" | ".cache" | ".venv" | ".tox" | ".mypy_cache"
                                       | ".pytest_cache" | ".gradle" | "__pycache__"
       --  A whole-file write's own partial (Editing.Replace), which a crash
       --  can leave beside the file: no file of the project's -- read as
       --  one it moved the revision and was a change no one made.
       or else Ada.Strings.Fixed.Index (Name, ".model_runner-partial.") > 0
       or else Named_By (Within.Skip, Relative));

   ----------
   -- Scan --
   ----------

   --  A scan into the graph given, which it begins empty: returned, a
   --  large tree's graph was copied out -- a second of humanize's /init,
   --  2.5 million references -- and copied again where it was assigned.
   procedure Scan_Into
     (Project_Directory : String;
      Within            : Roots;
      Result            : in out Graph)
   is
      Skip_File : exception;
      Texts    : Name_Lists.Vector;
      Paths    : Name_Lists.Vector;

      procedure Walk (Directory, Prefix : String) is
         Search : Dirs.Search_Type;
         Found  : Dirs.Directory_Entry_Type;
         Names  : Name_Lists.Vector;
      begin
         Dirs.Start_Search (Search, Directory, "");
         while Dirs.More_Entries (Search) loop
            Dirs.Get_Next_Entry (Search, Found);
            if not Skipped
              (Dirs.Simple_Name (Found),
               (if Prefix = "" then "" else Prefix & "/") & Dirs.Simple_Name (Found), Within)
            then
               Names.Append (Dirs.Simple_Name (Found));
            end if;
         end loop;
         Dirs.End_Search (Search);

         --  In order, so that two scans of the same tree are one graph.
         for Name of Sorted (Names) loop
            declare
               Full     : constant String := Hostkit.Fs.Join (Directory, Name);
               Relative : constant String :=
                 (if Prefix = "" then Name else Prefix & "/" & Name);
               --  Asked once, each asking a look at the file -- and asked
               --  here, in the statements, so a file gone as it is asked of
               --  is this entry's to say, not its directory's.
               Kind     : Dirs.File_Kind;
            begin
               Kind := Dirs.Kind (Full);
               if Kind = Dirs.Directory and then Hostkit.Fs.Is_Link (Full) then
                  --  A link to a directory is not followed, as version
                  --  control does not follow one: it may lead out of the
                  --  project, or back into it without end.
                  Result.Unread.Append (Relative & ": " & Link_Not_Followed);
               elsif Kind = Dirs.Directory then
                  Walk (Full, Relative);
               elsif Kind = Dirs.Ordinary_File then
                  declare
                     Text   : Unbounded_String;
                     Status : E.Error_Info;
                     Size   : constant Dirs.File_Size := Dirs.Size (Full);
                     --  Taken before it is read: a write between leaves a
                     --  stamp older than what was read, read again next time.
                     Stamp  : constant String := Stamp_Of (Full);
                     Print  : Unbounded_String;
                     use type Dirs.File_Size;
                  begin
                     if Size <= Largest_Read then
                        Files.Read_Text (Full, Text, Status);
                     else
                        --  Too large to read whole: printed a piece at a
                        --  time, so a change to it is still a change.
                        Files.Print_Of (Full, Print, Status);
                     end if;
                     if E.Is_Error (Status) then
                        Result.Unread.Append (Relative & ": could not be read");
                        raise Skip_File;
                     end if;
                     if Size <= Largest_Read then
                        Print := To_Unbounded_String (Fingerprint (To_String (Text)));
                     end if;
                     --  A built program or object -- bytes, not text, a NUL
                     --  among its first -- is no file of the project's.
                     if Ada.Strings.Unbounded.Index
                          (Ada.Strings.Unbounded.Head (Text, Natural'Min (8_192, Length (Text))),
                           [1 => ASCII.NUL]) > 0
                     then
                        Result.Skipped.Append (Relative & ASCII.HT & Stamp);
                        raise Skip_File;
                     end if;
                     Result.Reading := To_Unbounded_String (Relative);
                     Add_File
                       (Result,
                        (Path        => To_Unbounded_String (Relative),
                         Language    => To_Unbounded_String (Language_Of (Relative)),
                         Role        => (if Says_Generated (To_String (Text)) then Generated
                                         else Role_Of (Relative, Within)),
                         Fingerprint => Print,
                         Stamp       => To_Unbounded_String (Recorded (Stamp))));
                     declare
                        Reader : constant Adapter'Class :=
                          Languages.Adapter_For (Language_Of (Relative));
                     begin
                        Reader.Read (Relative, To_String (Text), Result);
                        if Reads_References (Relative) then
                           Paths.Append (Relative);
                           Texts.Append (To_String (Text));
                        end if;
                     end;
                  end;
               end if;
            exception
               when Skip_File =>
                  null;
               when Failure : others =>
                  --  Gone while walked, not to be opened, or stopped on
                  --  by its reader: left out of the graph, and said so.
                  Result.Unread.Append (Relative & ": " & Why (Failure));
            end;
         end loop;
      exception
         when Failure : others =>
            Result.Unread.Append
              ((if Prefix = "" then "." else Prefix) & ": " & Why (Failure));
      end Walk;
   begin
      declare
         Fresh : Graph;
      begin
         Result := Fresh;
      end;
      Walk (Project_Directory, "");

      --  References need every symbol, so they come after every file. An
      --  Ada file's are found from the graph as it stands, which nothing
      --  changes while they are, so several files' at once, each into a
      --  list of its own, and the lists added in the files' order: the
      --  same graph as one file at a time. humanize's 1,162 files spent
      --  four of /init's ten seconds here, on one processor of eight.
      Catch_Up (Result);
      declare
         Count : constant Natural := Natural (Paths.Length);
         Found : array (1 .. Count) of Relation_Lists.Vector;
         Is_Ada : array (1 .. Count) of Boolean;
         Failed : Ada.Exceptions.Exception_Occurrence;
         Fails  : Boolean := False;

         protected Dealer is
            procedure Next (Index : out Natural);
            procedure Fail (Failure : Ada.Exceptions.Exception_Occurrence);
         private
            Given : Natural := 0;
         end Dealer;

         protected body Dealer is
            procedure Next (Index : out Natural) is
            begin
               --  Past a failure no more are dealt: it is raised as a
               --  file at a time raised it.
               while Given < Count and then not Fails loop
                  Given := Given + 1;
                  if Is_Ada (Given) then
                     Index := Given;
                     return;
                  end if;
               end loop;
               Index := 0;
            end Next;

            procedure Fail (Failure : Ada.Exceptions.Exception_Occurrence) is
            begin
               if not Fails then
                  Ada.Exceptions.Save_Occurrence (Failed, Failure);
                  Fails := True;
               end if;
            end Fail;
         end Dealer;

         task type Finder;
         task body Finder is
            Index : Natural;
         begin
            loop
               Dealer.Next (Index);
               exit when Index = 0;
               Find_References (Paths (Index), Texts (Index), Result, Found (Index));
            end loop;
         exception
            when Failure : others =>
               Dealer.Fail (Failure);
         end Finder;

         Workers : constant Positive :=
           Positive'Max
             (1, Positive'Min
                   (Natural (System.Multiprocessors.Number_Of_CPUs),
                    Natural'Max (1, Count / 16)));
      begin
         for Index in 1 .. Count loop
            Is_Ada (Index) := Language_Of (Paths (Index)) = "Ada";
         end loop;
         declare
            Finders : array (1 .. Workers) of Finder with Unreferenced;
         begin
            null;
         end;
         if Fails then
            Ada.Exceptions.Reraise_Occurrence (Failed);
         end if;
         for Index in 1 .. Count loop
            Result.Reading := To_Unbounded_String (Paths (Index));
            if Is_Ada (Index) then
               for Item of Found (Index) loop
                  Add_Relation (Result, Item);
               end loop;
               Found (Index).Clear;
            else
               Languages.Adapter_For (Language_Of (Paths (Index))).Read_References
                 (Paths (Index), Texts (Index), Result);
            end if;
         end loop;
      end;
      Result.Reading := Null_Unbounded_String;
      Result.Within := Within;
      Result.Within_Known := True;
      Share_Names (Result);
   end Scan_Into;

   -------------
   -- Refresh --
   -------------

   --  Refresh, or with Check_Only only whether it would change anything:
   --  then the graph given back is empty, and nothing of Kept is copied --
   --  the copy, not the walk, was most of a refresh that found nothing.
   function Refresh_Or_Check
     (Project_Directory : String;
      Kept              : Graph;
      Read_Again        : out Natural;
      Within            : Roots;
      Check_Only        : Boolean;
      Unchanged         : out Boolean;
      --  The files whose references are to one of Names, where a graph's
      --  references are not all in memory -- one read from its record
      --  alone; Known false where it cannot say. Null: from Kept.
      Referrers         : access function
                            (Names : Name_Sets.Set; Known : out Boolean) return Name_Sets.Set := null)
      return Graph
   is
      Result   : Graph;

      --  The files there are now, in the order Scan walks them, with their
      --  stamps.
      Now_Paths  : Name_Lists.Vector;
      Now_Stamps : Name_Lists.Vector;

      --  What was read again, and the text of every Ada file whose
      --  references may have to be found again.
      Changed : Name_Lists.Vector;
      --  The same as a set, and the kept skipped lines: looked up file by
      --  file, each was a search of them all, and a refresh the square of
      --  a project's binary files, or of a branch switch's changes.
      Changed_Set : Name_Sets.Set;
      Skipped_Set : Name_Sets.Set;

      procedure Walk (Directory, Prefix : String) is
         Search : Dirs.Search_Type;
         Found  : Dirs.Directory_Entry_Type;
         Names  : Name_Lists.Vector;
      begin
         Dirs.Start_Search (Search, Directory, "");
         while Dirs.More_Entries (Search) loop
            Dirs.Get_Next_Entry (Search, Found);
            if not Skipped
              (Dirs.Simple_Name (Found),
               (if Prefix = "" then "" else Prefix & "/") & Dirs.Simple_Name (Found), Within)
            then
               Names.Append (Dirs.Simple_Name (Found));
            end if;
         end loop;
         Dirs.End_Search (Search);
         for Name of Sorted (Names) loop
            declare
               Full     : constant String := Hostkit.Fs.Join (Directory, Name);
               Relative : constant String :=
                 (if Prefix = "" then Name else Prefix & "/" & Name);
               --  Asked once, each asking a look at the file -- and asked
               --  here, in the statements, so a file gone as it is asked of
               --  is this entry's to say, not its directory's.
               Kind     : Dirs.File_Kind;
            begin
               Kind := Dirs.Kind (Full);
               if Kind = Dirs.Directory and then Hostkit.Fs.Is_Link (Full) then
                  Result.Unread.Append (Relative & ": " & Link_Not_Followed);
               elsif Kind = Dirs.Directory then
                  Walk (Full, Relative);
               elsif Kind = Dirs.Ordinary_File then
                  Now_Paths.Append (Relative);
                  Now_Stamps.Append (Stamp_Of (Full));
               end if;
            exception
               when Failure : others =>
                  Result.Unread.Append (Relative & ": " & Why (Failure));
            end;
         end loop;
      exception
         when Failure : others =>
            Result.Unread.Append
              ((if Prefix = "" then "." else Prefix) & ": " & Why (Failure));
      end Walk;

      --  The kept files by path, found once: searched file by file for
      --  each, a scan was the square of the files, nothing changed or not.
      Kept_At     : Word_Places.Map;
      Kept_Mapped : Boolean := False;

      function Kept_Index (Path : String) return Natural is
      begin
         if not Kept_Mapped then
            for Index in 1 .. Natural (Kept.Files.Length) loop
               if not Kept_At.Contains (To_String (Kept.Files (Index).Path)) then
                  Add_Place (Kept_At, To_String (Kept.Files (Index).Path), Index);
               end if;
            end loop;
            Kept_Mapped := True;
         end if;
         return (if Kept_At.Contains (Path) then Kept_At (Path).First_Element else 0);
      end Kept_Index;

      --  Whether the walk has a file down as unread.
      function Unreadable (Path : String) return Boolean is
      begin
         for Said of Result.Unread loop
            if Said'Length > Path'Length + 1
              and then Said (Said'First .. Said'First + Path'Length) = Path & ":"
            then
               return True;
            end if;
         end loop;
         return False;
      end Unreadable;

      --  The text of a file; one that cannot be read is put down as
      --  unread, and left out of the graph as a scan leaves it out.
      function Text_Of (Path : String) return String is
         Text   : Unbounded_String;
         Status : E.Error_Info;
         Full   : constant String := Hostkit.Fs.Join (Project_Directory, Path);
         use type Dirs.File_Size;
      begin
         if Dirs.Size (Full) <= Largest_Read then
            Files.Read_Text (Full, Text, Status);
            if E.Is_Error (Status) and then not Unreadable (Path) then
               Result.Unread.Append (Path & ": could not be read");
            end if;
         end if;
         return To_String (Text);
      exception
         when Failure : others =>
            if not Unreadable (Path) then
               Result.Unread.Append (Path & ": " & Why (Failure));
            end if;
            return "";
      end Text_Of;

      --  A file's print: of its text where it was read whole, else read
      --  a piece at a time; one that will not read is put down as unread.
      function Print_Of (Path, Text : String) return String is
         Full   : constant String := Hostkit.Fs.Join (Project_Directory, Path);
         Print  : Unbounded_String;
         Status : E.Error_Info;
         use type Dirs.File_Size;
      begin
         if Dirs.Size (Full) <= Largest_Read then
            return Fingerprint (Text);
         end if;
         Files.Print_Of (Full, Print, Status);
         if E.Is_Error (Status) and then not Unreadable (Path) then
            Result.Unread.Append (Path & ": could not be read");
         end if;
         return To_String (Print);
      exception
         when Failure : others =>
            if not Unreadable (Path) then
               Result.Unread.Append (Path & ": " & Why (Failure));
            end if;
            return "";
      end Print_Of;

      --  The units a set of files hold, from a graph.
      function Units_Of (From : Graph; Paths : Name_Sets.Set) return Name_Lists.Vector is
         Units : Name_Lists.Vector;
         Seen  : Name_Sets.Set;
      begin
         for Link of From.Relations loop
            if Link.Kind = Contains and then Paths.Contains (To_String (Link.From))
              and then not Seen.Contains (To_String (Link.To))
            then
               Seen.Include (To_String (Link.To));
               Units.Append (To_String (Link.To));
            end if;
         end loop;
         return Units;
      end Units_Of;

      --  Whether the roots now place a kept file otherwise. One generated
      --  by what it says, not where it is, stays so while it is unchanged.
      function Role_Moved (Was : File_Role; Path : String) return Boolean
      is (if Was = Generated
          then not Named_By (Within.Generated, Path) and then not Says_Generated (Text_Of (Path))
          else Was /= Role_Of (Path, Within));

      --  The files whose stamp was marked and whose text was found the same:
      --  their stamps as they are recorded now, by path.
      Confirmed : Stamp_Maps.Map;

      --  Whether a kept file is the text it was: by its stamp where the
      --  stamp can be trusted, else by its text's print against the kept
      --  one -- read, not parsed -- and its stamp recorded anew.
      function Same_Text (Held, Index : Positive) return Boolean is
         Was : constant String := To_String (Kept.Files (Held).Stamp);
         Now : constant String := Now_Stamps (Index);
      begin
         if Now /= "" and then Was = Now then
            return True;
         elsif Was /= "?" & Now then
            return False;
         end if;
         declare
            Path : constant String := Now_Paths (Index);
            Same : constant Boolean :=
              Print_Of (Path, Text_Of (Path)) = To_String (Kept.Files (Held).Fingerprint)
              and then not Unreadable (Path);
         begin
            if Same then
               Confirmed.Include (Path, Recorded (Now));
            end if;
            return Same;
         end;
      end Same_Text;

      --  A kept file's entry, its stamp as confirmed where it was.
      function Kept_Entry (Held : Positive) return File_Entry is
         Path : constant String := To_String (Kept.Files (Held).Path);
      begin
         return Item : File_Entry := Kept.Files (Held) do
            if Confirmed.Contains (Path) then
               Item.Stamp := To_Unbounded_String (Confirmed (Path));
            end if;
         end return;
      end Kept_Entry;

      Gone : Name_Lists.Vector;

      Symbols_Of   : Word_Places.Map;
      Relations_Of : Word_Places.Map;
      Units_In     : Name_Maps.Map;
      Depends      : Name_Maps.Map;
   begin
      Read_Again := 0;
      Walk (Project_Directory, "");

      for Line of Kept.Skipped loop
         Skipped_Set.Include (Line);
      end loop;
      --  What changed, and what went.
      for Index in 1 .. Natural (Now_Paths.Length) loop
         declare
            Held : constant Natural := Kept_Index (Now_Paths (Index));
            --  Left out as bytes when last seen, and not touched since:
            --  left out again, unread.
            Skip_Line : constant String := Now_Paths (Index) & ASCII.HT & Now_Stamps (Index);
         begin
            if Held = 0 and then Skipped_Set.Contains (Skip_Line) and then not Recent (Now_Stamps (Index)) then
               Result.Skipped.Append (Skip_Line);
            elsif Held = 0 or else not Same_Text (Held, Index)
              or else Role_Moved (Kept.Files (Held).Role, Now_Paths (Index))
            then
               Changed.Append (Now_Paths (Index));
               Changed_Set.Include (Now_Paths (Index));
            end if;
         end;
      end loop;
      declare
         Now_Set : Name_Sets.Set;
      begin
         for Path of Now_Paths loop
            Now_Set.Include (Path);
         end loop;
         for Item of Kept.Files loop
            if not Now_Set.Contains (To_String (Item.Path)) then
               Gone.Append (To_String (Item.Path));
            end if;
         end loop;
      end;
      Unchanged := Changed.Is_Empty and then Gone.Is_Empty;
      if Check_Only then
         return Empty : Graph;
      elsif Unchanged then
         return Same : Graph := Kept do
            Same.Unread := Result.Unread;
            Same.Skipped := Result.Skipped;
            Same.Within := Within;
            Same.Within_Known := True;
            for Index in 1 .. Natural (Same.Files.Length) loop
               if Confirmed.Contains (To_String (Same.Files (Index).Path)) then
                  Same.Files (Index) := Kept_Entry (Index);
               end if;
            end loop;
         end return;
      end if;

      --  The kept symbols and relations by the file they came from, so a
      --  file taken as it was is found without walking them all.
      for Index in 1 .. Natural (Kept.Symbols.Length) loop
         Add_Place (Symbols_Of, To_String (Kept.Symbols (Index).Path), Index);
      end loop;
      for Index in 1 .. Natural (Kept.Relations.Length) loop
         Add_Place (Relations_Of, To_String (Kept.Relations (Index).Origin), Index);
      end loop;

      --  Each file in order: as it was, or read again.
      for Index in 1 .. Natural (Now_Paths.Length) loop
         declare
            Path : constant String := Now_Paths (Index);
         begin
            Result.Reading := To_Unbounded_String (Path);
            if Changed_Set.Contains (Path) then
               declare
                  Text  : constant String := Text_Of (Path);
                  Print : constant String := Print_Of (Path, Text);
               begin
                  Read_Again := Read_Again + 1;
                  --  One that could not be read is left out, as Scan
                  --  leaves it out -- and a built program or object, bytes
                  --  not text, a NUL among its first, as Scan leaves it.
                  if not Unreadable (Path)
                    and then Ada.Strings.Fixed.Index
                               (Text (Text'First .. Text'First + Natural'Min (8_192, Text'Length) - 1),
                                [1 => ASCII.NUL]) > 0
                  then
                     Result.Skipped.Append (Path & ASCII.HT & Now_Stamps (Index));
                  end if;
                  if not Unreadable (Path)
                    and then Ada.Strings.Fixed.Index
                               (Text (Text'First .. Text'First + Natural'Min (8_192, Text'Length) - 1),
                                [1 => ASCII.NUL]) = 0
                  then
                     Add_File
                       (Result,
                        (Path        => To_Unbounded_String (Path),
                         Language    => To_Unbounded_String (Language_Of (Path)),
                         Role        => (if Says_Generated (Text) then Generated
                                         else Role_Of (Path, Within)),
                         Fingerprint => To_Unbounded_String (Print),
                         Stamp       => To_Unbounded_String (Recorded (Now_Stamps (Index)))));
                     begin
                        Languages.Adapter_For (Language_Of (Path)).Read (Path, Text, Result);
                     exception
                        when Failure : others =>
                           --  As a scan has it: what its reader stopped on.
                           Result.Unread.Append (Path & ": " & Why (Failure));
                     end;
                  end if;
               end;
            elsif Kept_Index (Path) = 0 then
               --  Bytes left out last time and not touched since: left out
               --  again (Result.Skipped has it), with nothing to carry.
               null;
            else
               Add_File (Result, Kept_Entry (Kept_Index (Path)));
               if Symbols_Of.Contains (Path) then
                  for Place of Symbols_Of.Constant_Reference (Path) loop
                     Result.Symbols.Append (Kept.Symbols (Place));
                  end loop;
               end if;
               if Relations_Of.Contains (Path) then
                  for Place of Relations_Of.Constant_Reference (Path) loop
                     if not Is_Reference (Kept.Relations (Place).Kind) then
                        Result.Relations.Append (Kept.Relations (Place));
                     end if;
                  end loop;
               end if;
            end if;
         end;
      end loop;

      --  References: found again for a changed file and for every file
      --  that can see a changed or removed unit; taken as they were for
      --  the rest.
      declare
         --  The changed files whose declarations changed: a file changed
         --  with every name it declares as it was -- a comment, a body --
         --  is not one another file's references can read otherwise, and
         --  reading again every file that can see it took seconds when
         --  the unit is one that hundreds of files use. One that only
         --  declares more (Grown) changes another file's references only
         --  where that file says one of the new names (Added_Words, their
         --  last parts in small letters): a use that found nothing before.
         Renamed, Grown : Name_Sets.Set;
         Added_Words    : Name_Sets.Set;

         --  The names no longer declared -- lost, changed in kind, or of a
         --  file gone: a reference only to one of them reads otherwise now,
         --  so only the files with such a reference (Who) are read again
         --  for them, not every file that can see their unit.
         Removed_Names  : Name_Sets.Set;

         function Declaring_Otherwise return Boolean is
            Was, Is_Now : Name_Maps.Map;
         begin
            for Named of Kept.Symbols loop
               if Changed_Set.Contains (To_String (Named.Path)) then
                  Add_Name (Was, To_String (Named.Path), To_String (Named.Name) & Tab & To_String (Named.Kind));
               end if;
            end loop;
            for Named of Result.Symbols loop
               if Changed_Set.Contains (To_String (Named.Path)) then
                  Add_Name (Is_Now, To_String (Named.Path), To_String (Named.Name) & Tab & To_String (Named.Kind));
               end if;
            end loop;
            for Path of Changed_Set loop
               declare
                  Before, After : Name_Sets.Set;
                  Gained        : Name_Sets.Set;
               begin
                  if Was.Contains (Path) then
                     for Name of Was.Element (Path) loop
                        Before.Include (Name);
                     end loop;
                  end if;
                  if Is_Now.Contains (Path) then
                     for Name of Is_Now.Element (Path) loop
                        After.Include (Name);
                     end loop;
                  end if;
                  if not Name_Sets.Is_Subset (Before, After) then
                     Renamed.Include (Path);
                     for Entry_Of of Name_Sets.Difference (Before, After) loop
                        Removed_Names.Include
                          (Entry_Of (Entry_Of'First .. Ada.Strings.Fixed.Index (Entry_Of, [Tab]) - 1));
                     end loop;
                  end if;
                  if not Name_Sets.Is_Subset (After, Before) then
                     Grown.Include (Path);
                     Gained := Name_Sets.Difference (After, Before);
                     for Entry_Of of Gained loop
                        declare
                           Name : constant String :=
                             Entry_Of (Entry_Of'First .. Ada.Strings.Fixed.Index (Entry_Of, [Tab]) - 1);
                           Cut  : Natural := Name'First - 1;
                        begin
                           for At_Char in Name'Range loop
                              if Name (At_Char) in '.' | ':' then
                                 Cut := At_Char;
                              end if;
                           end loop;
                           Added_Words.Include (Lower (Name (Cut + 1 .. Name'Last)));
                        end;
                     end loop;
                  end if;
               end;
            end loop;
            --  And every name a file gone declared.
            for Named of Kept.Symbols loop
               if Gone.Contains (To_String (Named.Path)) then
                  Removed_Names.Include (To_String (Named.Name));
               end if;
            end loop;
            return True;
         end Declaring_Otherwise;

         --  Whether a text says one of Added_Words, as a whole word.
         function Mentions (Text : String) return Boolean is
            Low   : constant String := Lower (Text);
            Start : Natural := 0;
         begin
            for At_Char in Low'First .. Low'Last + 1 loop
               if At_Char <= Low'Last
                 and then (Ada.Characters.Handling.Is_Alphanumeric (Low (At_Char)) or else Low (At_Char) = '_')
               then
                  if Start = 0 then
                     Start := At_Char;
                  end if;
               elsif Start > 0 then
                  if Added_Words.Contains (Low (Start .. At_Char - 1)) then
                     return True;
                  end if;
                  Start := 0;
               end if;
            end loop;
            return False;
         end Mentions;

         --  Renamed, Grown and Added_Words filled, before Moved is.
         Sorted_Out : constant Boolean := Declaring_Otherwise;
         pragma Unreferenced (Sorted_Out);

         --  The files with a reference to a removed name: from the kept
         --  graph's references, or asked where they are not in memory; not
         --  known, every file that can see the unit is read again, as
         --  before.
         Who       : Name_Sets.Set;
         Who_Known : Boolean := True;

         function Find_Who return Boolean is
         begin
            if Removed_Names.Is_Empty then
               return True;
            elsif Referrers /= null then
               Who := Referrers (Removed_Names, Who_Known);
            elsif Kept.Light then
               --  Its references not in memory and none to ask.
               Who_Known := False;
            end if;
            --  And those it holds: all of them, or for one read without
            --  them, those of the files read again since.
            for Link of Kept.Relations loop
               if Is_Reference (Link.Kind) and then Removed_Names.Contains (To_String (Link.To)) then
                  Who.Include (To_String (Link.Origin));
               end if;
            end loop;
            return True;
         end Find_Who;

         Who_Found : constant Boolean := Find_Who;
         pragma Unreferenced (Who_Found);
         Moved   : Name_Lists.Vector := Units_Of (Result, Renamed);
         Grown_Units : constant Name_Lists.Vector := Units_Of (Result, Grown);
         Grown_Set   : Name_Sets.Set;
         Gone_Set : Name_Sets.Set;
         function Gone_Units return Name_Lists.Vector is
         begin
            for Path of Gone loop
               Gone_Set.Include (Path);
            end loop;
            return Units_Of (Kept, Gone_Set);
         end Gone_Units;
         Removed : constant Name_Lists.Vector := Gone_Units;
         Moved_Set : Name_Sets.Set;
      begin
         for Unit of Moved loop
            Moved_Set.Include (Unit);
         end loop;
         for Unit of Grown_Units loop
            Grown_Set.Include (Unit);
         end loop;
         for Unit of Removed loop
            if not Moved_Set.Contains (Unit) then
               Moved.Append (Unit);
               Moved_Set.Include (Unit);
            end if;
         end loop;

         --  Each file's units, and what each unit depends on, in one walk.
         for Link of Result.Relations loop
            if Link.Kind = Contains then
               if not Units_In.Contains (To_String (Link.From))
                 or else not Units_In.Constant_Reference (To_String (Link.From)).Contains
                               (To_String (Link.To))
               then
                  Add_Name (Units_In, To_String (Link.From), To_String (Link.To));
               end if;
            elsif Link.Kind = Depends_On then
               Add_Name (Depends, To_String (Link.From), To_String (Link.To));
            end if;
         end loop;

         for Path of Now_Paths loop
            if Reads_References (Path) then
               declare
                  Own    : constant Name_Lists.Vector :=
                    (if Units_In.Contains (Path) then Units_In.Element (Path)
                     else Name_Lists.Empty_Vector);
                  --  Whether the file can see one of Units: one of its own,
                  --  one it depends on, or one of that unit's parents, which
                  --  a with of a child sees as well. A reader that finds what
                  --  is called by its name, not by what the file depends on
                  --  -- x.method (), a prefix of a module -- may see any unit
                  --  that changed, as a whole scan reads it.
                  function Can_See (Units : Name_Lists.Vector; Units_Set : Name_Sets.Set) return Boolean is
                  begin
                     for Unit of Own loop
                        if Units_Set.Contains (Unit) then
                           return True;
                        end if;
                        if Depends.Contains (Unit) then
                           for Target of Depends.Constant_Reference (Unit) loop
                              if Units_Set.Contains (Target)
                                or else (for some One of Units =>
                                           Target'Length > One'Length
                                           and then Target (Target'First .. Target'First + One'Length) = One & ".")
                              then
                                 return True;
                              end if;
                           end loop;
                        end if;
                     end loop;
                     return not Units.Is_Empty and then Language_Of (Path) /= "Ada";
                  end Can_See;

                  --  Read again: changed; with a reference to a name no
                  --  longer declared (or, where that is not known, able to
                  --  see a unit that lost one); or able to see a unit that
                  --  gained names where the file says one of them.
                  Sees : constant Boolean :=
                    Changed_Set.Contains (Path)
                    or else (if Who_Known then Who.Contains (Path) else Can_See (Moved, Moved_Set))
                    or else (Can_See (Grown_Units, Grown_Set) and then Mentions (Text_Of (Path)));
               begin
                  Result.Reading := To_Unbounded_String (Path);
                  if Sees then
                     Result.Touched.Append (Path);
                     if not Changed_Set.Contains (Path) then
                        Read_Again := Read_Again + 1;
                     end if;
                     Languages.Adapter_For (Language_Of (Path)).Read_References
                       (Path, Text_Of (Path), Result);
                  elsif Relations_Of.Contains (Path) then
                     for Place of Relations_Of.Constant_Reference (Path) loop
                        if Is_Reference (Kept.Relations (Place).Kind) then
                           Result.Relations.Append (Kept.Relations (Place));
                        end if;
                     end loop;
                  end if;
               end;
            end if;
         end loop;
      end;
      Result.Reading := Null_Unbounded_String;
      Result.Within := Within;
      Result.Within_Known := True;
      for Path of Gone loop
         Result.Touched.Append (Path);
      end loop;
      --  Read without its references: those of the files read again are
      --  its own from now on, not the buckets'.
      Result.Light := Kept.Light;
      if Kept.Light then
         Result.Held_Origins := Kept.Held_Origins;
         for Path of Result.Touched loop
            if not Result.Held_Origins.Contains (Path) then
               Result.Held_Origins.Append (Path);
            end if;
         end loop;
      end if;
      Share_Names (Result);
      return Result;
   end Refresh_Or_Check;

   function Refresh
     (Project_Directory : String;
      Kept              : Graph;
      Read_Again        : out Natural;
      Within            : Roots := Default_Roots) return Graph
   is
      Unchanged : Boolean;
   begin
      return Refresh_Or_Check (Project_Directory, Kept, Read_Again, Within, False, Unchanged);
   end Refresh;

   ----------------
   -- Is_Current --
   ----------------

   function Is_Current (Project_Directory : String; Kept : Graph) return Boolean is
      Read_Again : Natural;
      Unchanged  : Boolean;
      Ignored    : constant Graph :=
        Refresh_Or_Check (Project_Directory, Kept, Read_Again,
                          (if Kept.Within_Known then Kept.Within else Default_Roots), True, Unchanged);
      pragma Unreferenced (Ignored);
   begin
      return Unchanged;
   end Is_Current;

   ----------------
   -- Brought_Up --
   ----------------

   function Brought_Up (Project_Directory : String; Kept : Graph) return Graph is
      Read_Again : Natural;
   begin
      return Refresh (Project_Directory, Kept, Read_Again,
                      (if Kept.Within_Known then Kept.Within else Default_Roots));
   end Brought_Up;

   ------------
   -- Memory --
   ------------

   --  The graphs this process made last, by project and roots: a session
   --  asks of the same tree again and again, and a graph brought up to
   --  date reads only what changed. A few, for the workspaces beside it.
   --  Each with the fingerprint of the graph its project's state keeps,
   --  where this process knows it, so neither reading nor keeping has to
   --  load the kept one to learn it.
   Remembered_Count : constant := 4;

   type Remembered is record
      Key   : Unbounded_String;
      Found : Graph;
      Kept  : Unbounded_String;

      --  When it was last remembered: the oldest makes room. Entries are
      --  never moved, since a graph moved is a graph copied.
      Used  : Natural := 0;
   end record;

   Memory : array (1 .. Remembered_Count) of Remembered;
   Uses   : Natural := 0;

   --  Held while Memory is read or written, should two tasks scan at once.
   protected Memory_Lock is
      entry Seize;
      procedure Release;
   private
      Held : Boolean := False;
   end Memory_Lock;

   protected body Memory_Lock is
      entry Seize when not Held is
      begin
         Held := True;
      end Seize;

      procedure Release is
      begin
         Held := False;
      end Release;
   end Memory_Lock;

   --  What names a graph in Memory: the project's whole path and its roots.
   function Key_Of (Project_Directory : String; Within : Roots) return String is
      function Joined (Names : Name_Lists.Vector) return String is
         Text : Unbounded_String;
      begin
         for Name of Names loop
            Append (Text, Name & ASCII.LF);
         end loop;
         return To_String (Text);
      end Joined;

      Whole : constant String :=
        (if Dirs.Exists (Project_Directory) then Dirs.Full_Name (Project_Directory)
         else Project_Directory);
   begin
      return Whole & ASCII.NUL & Joined (Within.Skip) & ASCII.NUL & Joined (Within.Tests)
        & ASCII.NUL & Joined (Within.Documentation) & ASCII.NUL & Joined (Within.Generated);
   end Key_Of;

   --  The key of a store's project, with the roots it sets.
   function Key_Of (Item : Stores.Store) return String
   is (Key_Of (Ada.Directories.Containing_Directory (Stores.Root (Item)), Roots_Of (Item)));

   --  What Memory holds for a key: the graph, whether there is one, and the
   --  kept graph's fingerprint, empty where it is not known.
   procedure Recall
     (Key   : String;
      Found : out Graph;
      Held  : out Boolean;
      Kept  : out Unbounded_String) is
   begin
      Held := False;
      Kept := Null_Unbounded_String;
      Memory_Lock.Seize;
      for Index in Memory'Range loop
         if Memory (Index).Key = Key then
            Found := Memory (Index).Found;
            Kept := Memory (Index).Kept;
            Held := True;
            exit;
         end if;
      end loop;
      Memory_Lock.Release;
   end Recall;

   --  Remember a graph for a key, most recent first, with the kept graph's
   --  fingerprint where Kept says it; an empty one keeps what was known.
   procedure Remember (Key : String; Found : Graph; Kept : String := "") is
      Slot : Positive := Memory'First;
      Held : Boolean := False;
   begin
      Memory_Lock.Seize;
      for Index in Memory'Range loop
         if Memory (Index).Key = Key then
            Slot := Index;
            Held := True;
            exit;
         elsif Memory (Index).Used < Memory (Slot).Used then
            Slot := Index;
         end if;
      end loop;
      Uses := Uses + 1;
      Memory (Slot).Found := Found;
      Memory (Slot).Used := Uses;
      if not Held then
         Memory (Slot).Key := To_Unbounded_String (Key);
         Memory (Slot).Kept := To_Unbounded_String (Kept);
      elsif Kept /= "" then
         Memory (Slot).Kept := To_Unbounded_String (Kept);
      end if;
      Memory_Lock.Release;
   end Remember;

   --  Bring the graph Memory holds for a key up to date, in place: the
   --  graph is copied out once, and into Memory only where it changed.
   procedure Refresh_Remembered
     (Key               : String;
      Project_Directory : String;
      Within            : Roots;
      Found             : out Graph;
      Held              : out Boolean;
      Kept              : out Unbounded_String;
      --  For a graph read without its references: who has one to a name.
      Referrers         : access function
                            (Names : Name_Sets.Set; Known : out Boolean) return Name_Sets.Set := null;
      --  Only a graph with all its references, or none.
      Whole             : Boolean := False)
   is
      Read_Again : Natural;
      Unchanged  : Boolean;
   begin
      Held := False;
      Kept := Null_Unbounded_String;
      Memory_Lock.Seize;
      for Index in Memory'Range loop
         if Memory (Index).Key = Key and then not (Whole and then Memory (Index).Found.Light) then
            begin
               Found := Refresh_Or_Check (Project_Directory, Memory (Index).Found, Read_Again, Within, False,
                                          Unchanged, Referrers);
               if Read_Again > 0
                 or else Natural (Found.Files.Length) /= Natural (Memory (Index).Found.Files.Length)
               then
                  Memory (Index).Found := Found;
               end if;
               Uses := Uses + 1;
               Memory (Index).Used := Uses;
               Kept := Memory (Index).Kept;
               Held := True;
            exception
               when others =>
                  Memory_Lock.Release;
                  raise;
            end;
            exit;
         end if;
      end loop;
      Memory_Lock.Release;
   end Refresh_Remembered;

   function Split_Tabs (Text : String) return Name_Lists.Vector is
      Result : Name_Lists.Vector;
      Start  : Natural := Text'First;
   begin
      for Index in Text'First .. Text'Last + 1 loop
         if Index > Text'Last or else Text (Index) = Tab then
            Result.Append (Text (Start .. Index - 1));
            Start := Index + 1;
         end if;
      end loop;
      return Result;
   end Split_Tabs;

   --  The name a bucket of the graph's relations is kept under, of Count.
   function Bucket_Name (Bucket, Count : Positive) return String
   is (Index_Name & "-bucket-" & Records.Numbered (Bucket, Count));

   --  The record that says, for each bucket, the names its references are
   --  to: so that the files with a reference to a name are found by reading
   --  the buckets that have one, not all of them.
   Uses_Name : constant String := Index_Name & "-uses";

   --  Which of Count buckets a relation is kept in: by the file whose
   --  reading found it, so that a file read again changes its own bucket
   --  and no other.
   function Bucket_Of (Link : Relation; Count : Positive) return Positive
   is (Natural (Ada.Containers."mod" (Ada.Strings.Hash (To_String (Link.Origin)),
                                       Ada.Containers.Hash_Type (Count))) + 1);

   ---------------------
   -- Kept references --
   ---------------------

   procedure Load_Kept
     (Item        : Stores.Store;
      Found       : out Graph;
      Status      : out Model_Runner.Errors.Error_Info;
      Record_Only : Boolean);

   --  Each bucket of the graph kept in Item that may hold a reference to a
   --  name Asked takes -- one whose uses name one, every one where they are
   --  not kept or Asked is null -- read and its fields given to Take, the
   --  record not made: parsed and checked whole, the buckets naming one
   --  name much used took two seconds. Known false where
   --  the graph is not kept in buckets or one could not be read.
   procedure For_Kept_Buckets
     (Item  : Stores.Store;
      Asked : access function (Name : String) return Boolean;
      Take  : not null access procedure (Field, Text : String);
      Known : out Boolean;
      --  Where not empty, only the buckets these files' relations are in.
      Only  : Name_Lists.Vector := Name_Lists.Empty_Vector)
   is
      Read      : E.Error_Info;
      Uses_Read : E.Error_Info;
      Count     : Natural;

      --  Whether a bucket's uses, names a space apart, name one asked.
      function Names_One (Said : String) return Boolean is
         Start : Positive := Said'First;
      begin
         for Index in Said'First .. Said'Last + 1 loop
            if Index > Said'Last or else Said (Index) = ' ' then
               if Index > Start and then Asked (Said (Start .. Index - 1)) then
                  return True;
               end if;
               Start := Index + 1;
            end if;
         end loop;
         return False;
      end Names_One;

      --  Of the record and the uses, the fields asked here, walked: both
      --  made whole, the record's 6 MB took longer than the buckets.
      Reader, Buckets, Print     : Unbounded_String;
      Uses_Reader, Uses_Print    : Unbounded_String;
      Said                       : Name_Lists.Vector;

      procedure Take_Main (Field, Text : String) is
      begin
         if Field = "reader" then
            Reader := To_Unbounded_String (Text);
         elsif Field = "buckets" then
            Buckets := To_Unbounded_String (Text);
         elsif Field = "fingerprint" then
            Print := To_Unbounded_String (Text);
         end if;
      end Take_Main;

      procedure Take_Uses (Field, Text : String) is
      begin
         if Field = "reader" then
            Uses_Reader := To_Unbounded_String (Text);
         elsif Field = "fingerprint" then
            Uses_Print := To_Unbounded_String (Text);
         elsif Ada.Strings.Fixed.Index (Field, "bucket.") = Field'First then
            Said.Append (Text);
         end if;
      end Take_Uses;
   begin
      Known := False;
      Stores.Read_Fields (Item, Indexes_Area, Index_Name, Take_Main'Access, Read);
      if E.Is_Error (Read) or else To_String (Reader) /= Reader_Version or else Buckets = "" then
         return;
      end if;
      Count := Natural'Value (To_String (Buckets));
      if Asked /= null then
         Stores.Read_Fields (Item, Indexes_Area, Uses_Name, Take_Uses'Access, Uses_Read);
      end if;
      --  Uses of another graph than the record's, or of another reader:
      --  every bucket read, as where there are none.
      if Asked /= null and then E.Is_Ok (Uses_Read)
        and then (To_String (Uses_Reader) /= Reader_Version or else Uses_Print /= Print
                  or else Natural (Said.Length) /= Count)
      then
         Uses_Read := E.Make (E.Framework_Not_Found);
      end if;
      for Bucket in 1 .. Count loop
         if (Only.Is_Empty
             or else (for some Path of Only =>
                        Bucket_Of ((Origin => To_Unbounded_String (Path), others => <>), Count) = Bucket))
           and then (Asked = null or else E.Is_Error (Uses_Read) or else Names_One (Said (Bucket)))
         then
            Stores.Read_Fields (Item, Indexes_Area, Bucket_Name (Bucket, Count), Take, Read);
            if E.Is_Error (Read) then
               return;
            end if;
         end if;
      end loop;
      Known := True;
   exception
      when Constraint_Error =>
         Known := False;
   end For_Kept_Buckets;

   --  Of a relation's kept text, the name it is to and the file whose
   --  reading found it; "" for a text that is no relation.
   procedure Cut_Relation (Text : String; To_First, To_Last, Origin_First : out Natural) is
      First_Tab  : constant Natural := Ada.Strings.Fixed.Index (Text, [Tab]);
      Second_Tab : constant Natural :=
        (if First_Tab = 0 then 0 else Ada.Strings.Fixed.Index (Text (First_Tab + 1 .. Text'Last), [Tab]));
      Third_Tab  : constant Natural :=
        (if Second_Tab = 0 then 0 else Ada.Strings.Fixed.Index (Text (Second_Tab + 1 .. Text'Last), [Tab]));
      Last_Tab   : constant Natural := Ada.Strings.Fixed.Index (Text, [Tab], Ada.Strings.Backward);
   begin
      if Third_Tab = 0 then
         To_First := 1;
         To_Last := 0;
         Origin_First := Text'Last + 1;
      else
         To_First := Second_Tab + 1;
         To_Last := Third_Tab - 1;
         Origin_First := Last_Tab + 1;
      end if;
   end Cut_Relation;

   --  The files of a graph kept in Item with a reference to one of Names,
   --  from the buckets whose uses name one. Known false where that cannot
   --  be said.
   function Kept_Referrers
     (Item  : Stores.Store;
      Names : Name_Sets.Set;
      Known : out Boolean) return Name_Sets.Set
   is
      Result : Name_Sets.Set;

      function Asked (Name : String) return Boolean is (Names.Contains (Name));

      procedure Take (Field, Text : String) is
         To_First, To_Last, Origin_First : Natural;
      begin
         if Ada.Strings.Fixed.Index (Field, "relation.") = Field'First then
            Cut_Relation (Text, To_First, To_Last, Origin_First);
            if To_Last >= To_First and then Names.Contains (Text (To_First .. To_Last)) then
               Result.Include (Text (Origin_First .. Text'Last));
            end if;
         end if;
      end Take;
   begin
      For_Kept_Buckets (Item, Asked'Access, Take'Access, Known);
      return Result;
   end Kept_Referrers;

   --  Add to Into the references kept for a graph read without them whose
   --  names Wanted takes (every one where it is null): those of its files,
   --  but for the files read again since, whose own it holds.
   procedure Kept_Uses
     (Item   : Stores.Store;
      From   : Graph;
      Wanted : access function (Name : String) return Boolean;
      Into   : in out Relation_Vectors.Vector;
      Known  : out Boolean;
      Only   : Name_Lists.Vector := Name_Lists.Empty_Vector)
   is
      Files_Set : Name_Sets.Set;
      Held_Set  : Name_Sets.Set;
      Names     : Shared_Names.Map;

      procedure Take (Field, Text : String) is
         To_First, To_Last, Origin_First : Natural;
      begin
         if Ada.Strings.Fixed.Index (Field, "relation.") = Field'First then
            Cut_Relation (Text, To_First, To_Last, Origin_First);
            if To_Last >= To_First
              and then (Wanted = null or else Wanted (Text (To_First .. To_Last)))
              and then Files_Set.Contains (Text (Origin_First .. Text'Last))
              and then not Held_Set.Contains (Text (Origin_First .. Text'Last))
              and then (Only.Is_Empty or else Only.Contains (Text (Origin_First .. Text'Last)))
            then
               declare
                  Parts : constant Name_Lists.Vector := Split_Tabs (Text);
               begin
                  if Natural (Parts.Length) = 7 then
                     Into.Append
                       (Relation'
                        (Kind   => Relation_Kind'Value (Parts (1)),
                         From   => Shared (Names, Parts (2)),
                         To     => Shared (Names, Parts (3)),
                         Source => Derivation'Value (Parts (4)),
                         Sure   => Confidence'Value (Parts (5)),
                         Where  => To_Unbounded_String (Parts (6)),
                         Origin => Shared (Names, Parts (7))));
                  end if;
               end;
            end if;
         end if;
      end Take;
   begin
      for File of From.Files loop
         Files_Set.Include (To_String (File.Path));
      end loop;
      for Path of From.Held_Origins loop
         Held_Set.Include (Path);
      end loop;
      For_Kept_Buckets (Item, Wanted, Take'Access, Known, Only);
   end Kept_Uses;

   ----------------------
   -- Holds_References --
   ----------------------

   function Holds_References (From : Graph) return Boolean is (not From.Light);

   -----------
   -- Whole --
   -----------

   function Whole (Item : Stores.Store; From : Graph) return Graph is
      Known : Boolean;
   begin
      if not From.Light then
         return From;
      end if;
      return Result : Graph := From do
         Kept_Uses (Item, From, null, Result.Relations, Known);
         if not Known then
            --  The buckets not as the record says: the kept graph whole,
            --  brought up to date, as before there were buckets.
            declare
               Kept       : Graph;
               Read       : E.Error_Info;
               Read_Again : Natural;
            begin
               Load (Item, Kept, Read);
               Result := Refresh (Ada.Directories.Containing_Directory (Stores.Root (Item)), Kept,
                                  Read_Again, Roots_Of (Item));
            end;
         end if;
         Result.Light := False;
         Result.Held_Origins.Clear;
         Share_Names (Result);
      end return;
   end Whole;

   -------------
   -- Uses_Of --
   -------------

   function Uses_Of
     (Item     : Stores.Store;
      From     : Graph;
      Wanted   : not null access function (Name : String) return Boolean;
      In_Files : Name_Lists.Vector := Name_Lists.Empty_Vector) return Relation_Lists.Vector
   is
      Found : Relation_Lists.Vector;
      Known : Boolean := True;

      function Taken (Link : Relation) return Boolean
      is (Is_Reference (Link.Kind) and then Wanted (To_String (Link.To))
          and then (In_Files.Is_Empty or else In_Files.Contains (To_String (Link.Origin))));
   begin
      for Link of From.Relations loop
         if Taken (Link) then
            Found.Append (Link);
         end if;
      end loop;
      if not From.Light then
         return Found;
      end if;
      Kept_Uses (Item, From, Wanted, Found, Known, In_Files);
      if not Known then
         Found.Clear;
         for Link of Whole (Item, From).Relations loop
            if Taken (Link) then
               Found.Append (Link);
            end if;
         end loop;
         return Found;
      end if;
      --  In the order of the graph's files, as a graph that holds them has
      --  them: what is offered first is the same either way.
      declare
         package Origin_Maps is new Ada.Containers.Indefinite_Hashed_Maps
           (Key_Type => String, Element_Type => Relation_Lists.Vector, Hash => Ada.Strings.Hash,
            Equivalent_Keys => "=", "=" => Relation_Lists."=");
         By_Origin : Origin_Maps.Map;
         Result    : Relation_Lists.Vector;
      begin
         for Link of Found loop
            declare
               Origin : constant String := To_String (Link.Origin);
            begin
               if not By_Origin.Contains (Origin) then
                  By_Origin.Insert (Origin, Relation_Lists.Empty_Vector);
               end if;
               By_Origin.Reference (Origin).Append (Link);
            end;
         end loop;
         for File of From.Files loop
            if By_Origin.Contains (To_String (File.Path)) then
               Result.Append (By_Origin.Element (To_String (File.Path)));
            end if;
         end loop;
         return Result;
      end;
   end Uses_Of;

   ----------------
   -- Warming up --
   ----------------

   --  A graph read in the background, by the project it is of.
   protected Warming is
      --  Taken for Key, where none is under way.
      procedure Claim (Key : String; Got : out Boolean);
      procedure Release;
      --  Whether the read under way is of Key.
      function Holds (Key : String) return Boolean;
      --  Until no read is under way.
      entry Await;
      procedure Ask_Stop;
      function Stopping return Boolean;
   private
      Held     : Boolean := False;
      Held_Key : Unbounded_String;
      Stop     : Boolean := False;
   end Warming;

   protected body Warming is
      procedure Claim (Key : String; Got : out Boolean) is
      begin
         Got := not Held and then not Stop;
         if Got then
            Held := True;
            Held_Key := To_Unbounded_String (Key);
         end if;
      end Claim;

      procedure Release is
      begin
         Held := False;
         Held_Key := Null_Unbounded_String;
      end Release;

      function Holds (Key : String) return Boolean is (Held and then To_String (Held_Key) = Key);

      entry Await when not Held is
      begin
         null;
      end Await;

      procedure Ask_Stop is
      begin
         Stop := True;
      end Ask_Stop;

      function Stopping return Boolean is (Stop);
   end Warming;

   --  Raised in a background read told to stop.
   Warm_Up_Stopped : exception;

   --  Wait for a background read of Key, where one is under way: what it
   --  reads is in memory once it ends.
   procedure Wait_For_Warm_Up (Key : String) is
   begin
      if Warming.Holds (Key) then
         Warming.Await;
      end if;
   end Wait_For_Warm_Up;

   --  The reader: one read at a time, a project's graph by its directory.
   task Warmer is
      entry Take (Project_Directory : String; Then_Warm : After_Warm_Up);
   end Warmer;

   procedure Stop_Warm_Up is
   begin
      Warming.Ask_Stop;
   end Stop_Warm_Up;

   ---------
   -- Now --
   ---------

   function Now (Item : Stores.Store) return Graph is
      Key        : constant String := Key_Of (Item);
      Kept       : Graph;
      Held       : Boolean;
      Kept_Print : Unbounded_String;
      Read       : E.Error_Info;
      Read_Again : Natural;
      Unchanged  : Boolean;

      function Referrers (Names : Name_Sets.Set; Known : out Boolean) return Name_Sets.Set
      is (Kept_Referrers (Item, Names, Known));
   begin
      --  Not the background read itself, which reads by a store opened
      --  only to be read, and would wait for its own end.
      if not Stores.Is_Read_Only (Item) then
         Wait_For_Warm_Up (Key);
      end if;
      return Result : Graph do
         Refresh_Remembered
           (Key, Ada.Directories.Containing_Directory (Stores.Root (Item)), Roots_Of (Item),
            Result, Held, Kept_Print, Referrers'Access);
         if not Held then
            --  A graph kept in buckets without the references in them: a
            --  tenth of the memory, and those asked for read when asked.
            Load_Kept (Item, Kept, Read, Record_Only => True);
            Result := Refresh_Or_Check (Ada.Directories.Containing_Directory (Stores.Root (Item)), Kept,
                                        Read_Again, Roots_Of (Item), False, Unchanged, Referrers'Access);
            Remember (Key, Result, (if E.Is_Ok (Read) then Graph_Fingerprint (Kept) else ""));
         end if;
      end return;
   end Now;

   -------------
   -- Current --
   -------------

   procedure Current
     (Item   : in out Stores.Store;
      Found  : out Graph;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Key        : constant String := Key_Of (Item);
      Kept       : Graph;
      Held       : Boolean;
      Kept_Print : Unbounded_String;
      Read       : E.Error_Info;
      Read_Again : Natural;
      Change     : Stores.Transaction;

      function Referrers (Names : Name_Sets.Set; Known : out Boolean) return Name_Sets.Set
      is (Kept_Referrers (Item, Names, Known));
   begin
      Status := E.Success;
      Wait_For_Warm_Up (Key);

      --  Known here: brought up to date from what this process holds, and
      --  kept where that is not what the state keeps.
      Refresh_Remembered
        (Key, Ada.Directories.Containing_Directory (Stores.Root (Item)), Roots_Of (Item),
         Found, Held, Kept_Print, Referrers'Access);
      if Held and then Kept_Print /= Null_Unbounded_String then
         if Graph_Fingerprint (Found) /= To_String (Kept_Print) then
            Keep (Item, Change, Found, Status);
            if E.Is_Ok (Status) then
               Stores.Commit (Item, Change, Status);
            end if;
         end if;
         return;
      end if;

      Load (Item, Kept, Read);
      if E.Is_Error (Read) then
         --  None kept: the tree scanned, not refreshed from nothing -- the
         --  same graph, its references read without asking what changed.
         Scan_Into (Ada.Directories.Containing_Directory (Stores.Root (Item)), Roots_Of (Item), Found);
         Read_Again := 0;
      else
         Found := Refresh (Ada.Directories.Containing_Directory (Stores.Root (Item)), Kept,
                           Read_Again, Roots_Of (Item));
      end if;
      if Read_Again > 0 or else E.Is_Error (Read)
        or else Natural (Found.Files.Length) /= Natural (Kept.Files.Length)
      then
         Keep (Item, Change, Found, Status);
         if E.Is_Ok (Status) then
            Stores.Commit (Item, Change, Status);
         end if;
      else
         Remember (Key, Found, Graph_Fingerprint (Kept));
      end if;
   end Current;

   ------------------------
   -- Kept_Fingerprint --
   ------------------------

   function Kept_Fingerprint (Item : Stores.Store) return String is
      Key        : constant String := Key_Of (Item);
      Kept       : Graph;
      Held       : Boolean;
      Kept_Print : Unbounded_String;
      Read       : E.Error_Info;
   begin
      Recall (Key, Kept, Held, Kept_Print);
      if Kept_Print /= Null_Unbounded_String then
         return To_String (Kept_Print);
      end if;
      Load (Item, Kept, Read);
      return (if E.Is_Ok (Read) and then Natural (Kept.Files.Length) > 0
              then Graph_Fingerprint (Kept) else "");
   end Kept_Fingerprint;

   ----------
   -- Scan --
   ----------

   function Scan
     (Project_Directory : String;
      Within            : Roots := Default_Roots) return Graph
   is
      Key        : constant String := Key_Of (Project_Directory, Within);
      Held       : Boolean;
      Kept_Print : Unbounded_String;
   begin
      return Result : Graph do
         Refresh_Remembered (Key, Project_Directory, Within, Result, Held, Kept_Print, Whole => True);
         if not Held then
            Scan_Into (Project_Directory, Within, Result);
            Remember (Key, Result);
         end if;
      end return;
   end Scan;

   ---------------------------------------------------------------------------
   --  Keeping.
   ---------------------------------------------------------------------------

   ---------------------
   -- Kept_Is_Current --
   ---------------------

   procedure Kept_Is_Current
     (Item  : Stores.Store;
      Fresh : out Boolean;
      Files : out Graph)
   is
      Value      : Records.Item;
      Read       : E.Error_Info;
      Kept       : Graph;
      Read_Again : Natural;
      Unchanged  : Boolean;
      Directory  : constant String := Ada.Directories.Containing_Directory (Stores.Root (Item));
   begin
      Fresh := False;
      Files := (others => <>);
      Stores.Read (Item, Indexes_Area, Index_Name, Value, Read);
      if E.Is_Error (Read) or else Records.Get (Value, "reader") /= Reader_Version then
         return;
      end if;
      for Index in 1 .. Records.Field_Count (Value) loop
         declare
            Field : constant String := Records.Field_Name (Value, Index);
         begin
            if Field'Length > 5 and then Field (Field'First .. Field'First + 4) = "file." then
               declare
                  Parts : constant Name_Lists.Vector := Split_Tabs (Records.Field_Value (Value, Index));
               begin
                  if Natural (Parts.Length) not in 4 .. 5 then
                     return;
                  end if;
                  Kept.Files.Append
                    (File_Entry'
                     (Path        => To_Unbounded_String (Parts (1)),
                      Language    => To_Unbounded_String (Parts (2)),
                      Role        => File_Role'Value (Parts (3)),
                      Fingerprint => To_Unbounded_String (Parts (4)),
                      Stamp       => To_Unbounded_String
                                       (if Natural (Parts.Length) = 5 then Parts (5) else "")));
               end;
            end if;
         end;
      end loop;
      --  The walk asked first whether anything would change; only then the
      --  graph it would make of the files, for what it could not read and
      --  the files of bytes, which the fingerprint holds too.
      declare
         Ignored : constant Graph :=
           Refresh_Or_Check (Directory, Kept, Read_Again, Roots_Of (Item), True, Unchanged);
         pragma Unreferenced (Ignored);
      begin
         if not Unchanged then
            return;
         end if;
      end;
      Files := Refresh_Or_Check (Directory, Kept, Read_Again, Roots_Of (Item), False, Unchanged);
      Fresh := Unchanged and then Graph_Fingerprint (Files) = Records.Get (Value, "fingerprint");
   exception
      when Constraint_Error =>
         Fresh := False;
         Files := (others => <>);
   end Kept_Is_Current;

   ----------
   -- Keep --
   ----------

   --  How many bytes a record of the graph is held to: under what a read
   --  takes whole (Records.Max_Bytes), with room for the record's own
   --  lines. A graph within it is kept in one record, as it always was;
   --  one past it keeps its relations in parts of their own -- humanize's
   --  2.5 million references, 580 MB, were refused as one record, and
   --  every session read the tree again for want of it.
   Part_Bytes : Long_Long_Integer := 48 * 1024 * 1024 with Atomic;

   procedure Keep_Parts_At_Most (Bytes : Positive) is
   begin
      Part_Bytes := Long_Long_Integer (Bytes);
   end Keep_Parts_At_Most;

   function Parts_At_Most return Positive is (Positive (Part_Bytes));

   --  The name a part of the graph's relations is kept under.
   function Part_Name (Part : Positive) return String
   is (Index_Name & "-part-" & Records.Numbered (Part, Part));

   --  The names the references of some relation texts are to, each once,
   --  a space apart.
   function Names_Said (Lines : Name_Lists.Vector) return String is
      Seen : Name_Sets.Set;
      Said : Unbounded_String;
   begin
      for Line of Lines loop
         declare
            First_Tab  : constant Natural := Ada.Strings.Fixed.Index (Line, [Tab]);
            Second_Tab : constant Natural :=
              (if First_Tab = 0 then 0 else Ada.Strings.Fixed.Index (Line (First_Tab + 1 .. Line'Last), [Tab]));
            Third_Tab  : constant Natural :=
              (if Second_Tab = 0 then 0 else Ada.Strings.Fixed.Index (Line (Second_Tab + 1 .. Line'Last), [Tab]));
         begin
            if Third_Tab > 0 and then not Seen.Contains (Line (Second_Tab + 1 .. Third_Tab - 1)) then
               Seen.Include (Line (Second_Tab + 1 .. Third_Tab - 1));
               Append (Said, (if Length (Said) = 0 then "" else " ") & Line (Second_Tab + 1 .. Third_Tab - 1));
            end if;
         end;
      end loop;
      return To_String (Said);
   end Names_Said;

   --  The fewest buckets a graph past one record keeps its relations in;
   --  more, by doubling, where a bucket would be past what a record holds.
   Least_Buckets : constant := 64;

   function Relation_Text (Link : Relation) return String
   is (Lower (Relation_Kind'Image (Link.Kind)) & Tab
       & To_String (Link.From) & Tab & To_String (Link.To) & Tab
       & Lower (Derivation'Image (Link.Source)) & Tab
       & Lower (Confidence'Image (Link.Sure)) & Tab
       & To_String (Link.Where) & Tab & To_String (Link.Origin));

   --  How long Relation_Text's text is, not made.
   function Relation_Text_Length (Link : Relation) return Natural
   is (Relation_Kind'Image (Link.Kind)'Length + Length (Link.From) + Length (Link.To)
       + Derivation'Image (Link.Source)'Length + Confidence'Image (Link.Sure)'Length
       + Length (Link.Where) + Length (Link.Origin) + 6);

   --  What a field takes in a record past its value: its name, its
   --  value's length, and the line breaks, about.
   Field_Bytes : constant := 32;

   --  A graph's files, symbols and what they declare, without its
   --  references: as a graph kept in buckets is held in memory.
   function Declared_Of (From : Graph) return Graph is
   begin
      return Result : Graph :=
        (Files => From.Files, Symbols => From.Symbols, Unread => From.Unread, Skipped => From.Skipped,
         Within => From.Within, Within_Known => From.Within_Known, Light => True, others => <>)
      do
         for Link of From.Relations loop
            if not Is_Reference (Link.Kind) then
               Result.Relations.Append (Link);
            end if;
         end loop;
      end return;
   end Declared_Of;

   procedure Keep_Graph
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Found  : Graph;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Value : Records.Item :=
        Records.Create
          (Schemas.Repository_Schema, 1, "REPOSITORY",
           Stores.Current_Revision (Item, Indexes_Area, Index_Name) + 1);
      Print     : constant String := Graph_Fingerprint (Found);
      Relations : constant Natural := Natural (Found.Relations.Length);

      --  The relations' bytes: whether they go in buckets.
      Spread : Long_Long_Integer := 0;
      Parts  : constant Natural := 0;

      --  The fields of the relations from First to Last, in Into.
      procedure Set_Relations (Into : in out Records.Item; First, Last : Natural) is
      begin
         for Index in First .. Last loop
            Records.Set (Into, "relation." & Records.Numbered (Index, Relations),
                         Relation_Text (Found.Relations (Index)));
         end loop;
      end Set_Relations;

   begin
      Status := E.Success;
      for Link of Found.Relations loop
         Spread := Spread + Long_Long_Integer (Relation_Text_Length (Link) + Field_Bytes);
      end loop;
      --  In the order the record keeps its fields -- file, fingerprint,
      --  parts, reader, relation, symbol -- so each is set at the end.
      for Index in 1 .. Natural (Found.Files.Length) loop
         declare
            File : File_Entry renames Found.Files (Index);
         begin
            Records.Set
              (Value, "file." & Records.Numbered (Index, Natural (Found.Files.Length)),
               To_String (File.Path) & Tab & To_String (File.Language) & Tab
               & Lower (File_Role'Image (File.Role)) & Tab
               & To_String (File.Fingerprint) & Tab & To_String (File.Stamp));
         end;
      end loop;
      Records.Set (Value, "fingerprint", Print);
      if Spread <= Part_Bytes then
         Records.Set (Value, "reader", Reader_Version);
         Set_Relations (Value, 1, Relations);
      else
         --  Past one record: in buckets, each relation in the one its
         --  finder's path falls in, and a bucket written only where what it
         --  holds changed -- one file read again rewrites its bucket, not
         --  the graph's 600 MB.
         declare
            Count : Positive := Least_Buckets;
            Old   : Records.Item;
            Read  : E.Error_Info;
            Had   : Natural := 0;
         begin
            while Spread / Long_Long_Integer (Count) > Part_Bytes / 2 and then Count < 65_536 loop
               Count := Count * 2;
            end loop;
            if Stores.Exists (Item, Indexes_Area, Index_Name) then
               Stores.Read (Item, Indexes_Area, Index_Name, Old, Read);
               if E.Is_Ok (Read) and then Records.Get (Old, "buckets") /= ""
                 and then Records.Get (Old, "reader") = Reader_Version
               then
                  Had := Natural'Value (Records.Get (Old, "buckets"));
               end if;
            end if;
            declare
               type Index_List is array (Positive range <>) of Natural;
               type Index_List_Access is access Index_List;
               procedure Free is new Ada.Unchecked_Deallocation (Index_List, Index_List_Access);
               --  Each relation's bucket, and how many each bucket holds.
               Into  : Index_List_Access := new Index_List (1 .. Natural'Max (1, Relations));
               Sizes : array (1 .. Count) of Natural := [others => 0];
               Declared : Natural := 0;
            begin
               --  A reference goes in its bucket; what a file declares stays
               --  in the record (0), so that a graph without its references
               --  -- the record alone -- is one a refresh can work from.
               for Index in 1 .. Relations loop
                  if Is_Reference (Found.Relations (Index).Kind) then
                     Into (Index) := Bucket_Of (Found.Relations (Index), Count);
                     Sizes (Into (Index)) := Sizes (Into (Index)) + 1;
                  else
                     Into (Index) := 0;
                     Declared := Declared + 1;
                  end if;
               end loop;
               declare
                  --  Each bucket's relations, so each is made into text once.
                  type Place_List_Array is array (1 .. Count) of Place_Lists.Vector;
                  Held : Place_List_Array;
               begin
                  for Index in 1 .. Relations loop
                     if Into (Index) > 0 then
                        Held (Into (Index)).Append (Index);
                     end if;
                  end loop;
                  for Bucket in 1 .. Count loop
                     declare
                        Field : constant String := "bucket." & Records.Numbered (Bucket, Count);
                        Print : Interfaces.Unsigned_64 := Hash ("");
                        Kept  : Records.Item :=
                          Records.Create
                            (Schemas.Repository_Schema, 1,
                             "REPOSITORY-BUCKET-" & Records.Numbered (Bucket, Count),
                             Stores.Current_Revision (Item, Indexes_Area, Bucket_Name (Bucket, Count)) + 1);
                        Shown : Natural := 0;
                     begin
                        --  Its fields set in their order: fingerprint, reader
                        --  and then the relations are placed as they come.
                        Records.Set (Kept, "fingerprint", "");
                        Records.Set (Kept, "reader", Reader_Version);
                        for Index of Held (Bucket) loop
                           declare
                              Text : constant String := Relation_Text (Found.Relations (Index));
                           begin
                              Print := Hash_On (Text & ASCII.LF, Print);
                              Shown := Shown + 1;
                              Records.Set (Kept, "relation." & Records.Numbered (Shown, Sizes (Bucket)), Text);
                           end;
                        end loop;
                        declare
                           Its : constant String := Fingerprint_Of (Print);
                        begin
                           Records.Set (Value, Field, Its);
                           Records.Set (Kept, "fingerprint", Its);
                           if not (Had = Count and then Records.Get (Old, Field) = Its
                                   and then Stores.Exists (Item, Indexes_Area, Bucket_Name (Bucket, Count)))
                           then
                              Stores.Put (Change, Indexes_Area, Bucket_Name (Bucket, Count), Kept);
                           end if;
                        end;
                     end;
                  end loop;
               end;
               --  What each bucket's references are to.
               declare
                  Uses : Records.Item :=
                    Records.Create (Schemas.Repository_Schema, 1, "REPOSITORY-USES",
                                    Stores.Current_Revision (Item, Indexes_Area, Uses_Name) + 1);
                  type Name_Set_Array is array (1 .. Count) of Name_Sets.Set;
                  Said : Name_Set_Array;
               begin
                  for Index in 1 .. Relations loop
                     if Into (Index) > 0 then
                        Said (Into (Index)).Include (To_String (Found.Relations (Index).To));
                     end if;
                  end loop;
                  for Bucket in 1 .. Count loop
                     declare
                        Joined : Unbounded_String;
                     begin
                        for Name of Said (Bucket) loop
                           Append (Joined, (if Length (Joined) = 0 then "" else " ") & Name);
                        end loop;
                        Records.Set (Uses, "bucket." & Records.Numbered (Bucket, Count), To_String (Joined));
                     end;
                  end loop;
                  Records.Set (Uses, "fingerprint", Print);
                  Records.Set (Uses, "reader", Reader_Version);
                  Stores.Put (Change, Indexes_Area, Uses_Name, Uses);
               end;
               --  The declared relations, in the record itself.
               declare
                  Shown : Natural := 0;
               begin
                  for Index in 1 .. Relations loop
                     if Into (Index) = 0 then
                        Shown := Shown + 1;
                        Records.Set (Value, "relation." & Records.Numbered (Shown, Declared),
                                     Relation_Text (Found.Relations (Index)));
                     end if;
                  end loop;
               end;
               Free (Into);
            end;
            Records.Set (Value, "buckets", Image (Count));
            Records.Set (Value, "reader", Reader_Version);
            --  The buckets an earlier graph kept in a count this one does not.
            if Had /= Count then
               for Bucket in 1 .. Had loop
                  if Stores.Exists (Item, Indexes_Area, Bucket_Name (Bucket, Had)) then
                     Stores.Remove (Change, Indexes_Area, Bucket_Name (Bucket, Had));
                  end if;
               end loop;
            end if;
         end;
      end if;
      for Index in 1 .. Natural (Found.Symbols.Length) loop
         declare
            Named : Symbol renames Found.Symbols (Index);
         begin
            Records.Set
              (Value, "symbol." & Records.Numbered (Index, Natural (Found.Symbols.Length)),
               To_String (Named.Name) & Tab & To_String (Named.Kind) & Tab
               & To_String (Named.Path) & Tab & Image (Named.Line));
         end;
      end loop;
      Stores.Put (Change, Indexes_Area, Index_Name, Value);

      --  The buckets of an earlier, larger graph, where this one is whole.
      if Spread <= Part_Bytes and then Stores.Exists (Item, Indexes_Area, Index_Name) then
         declare
            Old  : Records.Item;
            Read : E.Error_Info;
         begin
            Stores.Read (Item, Indexes_Area, Index_Name, Old, Read);
            if E.Is_Ok (Read) and then Records.Get (Old, "buckets") /= "" then
               declare
                  Had : constant Natural := Natural'Value (Records.Get (Old, "buckets"));
               begin
                  for Bucket in 1 .. Had loop
                     if Stores.Exists (Item, Indexes_Area, Bucket_Name (Bucket, Had)) then
                        Stores.Remove (Change, Indexes_Area, Bucket_Name (Bucket, Had));
                     end if;
                  end loop;
               end;
            end if;
         end;
         if Stores.Exists (Item, Indexes_Area, Uses_Name) then
            Stores.Remove (Change, Indexes_Area, Uses_Name);
         end if;
      end if;

      --  The parts an earlier graph kept, which no graph keeps now: let go.
      declare
         Next : Positive := Parts + 1;
      begin
         while Stores.Exists (Item, Indexes_Area, Part_Name (Next)) loop
            Stores.Remove (Change, Indexes_Area, Part_Name (Next));
            Next := Next + 1;
         end loop;
      end;

      --  What the state will keep, known here from now on: a graph in
      --  buckets without the references in them.
      Remember (Key_Of (Item), (if Spread <= Part_Bytes then Found else Declared_Of (Found)), Print);
   end Keep_Graph;

   procedure Keep
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Found  : Graph;
      Status : out Model_Runner.Errors.Error_Info) is
   begin
      --  One read without its references kept with them.
      Keep_Graph (Item, Change, (if Found.Light then Whole (Item, Found) else Found), Status);
   end Keep;

   ----------
   -- Load --
   ----------

   --  Load, or with Record_Only the graph's record alone: its files, its
   --  symbols and what its files declare, and no reference kept in a
   --  bucket -- what a refresh of a large graph works from.
   procedure Load_Kept
     (Item        : Stores.Store;
      Found       : out Graph;
      Status      : out Model_Runner.Errors.Error_Info;
      Record_Only : Boolean)
   is
      Value : Records.Item;

      --  The names its relations say, each held once as it is read: shared
      --  after the reading instead, the copies were made all the same, and
      --  the memory they took was the process's from then on.
      Names : Shared_Names.Map;

      --  The last relation's file and the file whose reading found it: the
      --  next relation is mostly from the same, and the same is taken
      --  without asking Names.
      Last_From, Last_Origin : Unbounded_String;

      function Again (Last : in out Unbounded_String; Text : String) return Unbounded_String is
      begin
         if Last /= Text then
            Last := Shared (Names, Text);
         end if;
         return Last;
      end Again;

      --  The graph's files, symbols and relations, from a record of it:
      --  each field by its place, a relation cut at its tabs where it lies
      --  -- by its name and through a list of its parts, a graph of 2.5
      --  million relations took nine seconds to read.
      procedure Take (From : Records.Item) is
         use type Ada.Containers.Count_Type;
      begin
         --  Room for this record's relations at least, grown by doubling:
         --  reserved a part at a time, every part copied all before it.
         if Found.Relations.Capacity < Found.Relations.Length + Ada.Containers.Count_Type (Records.Field_Count (From))
         then
            Found.Relations.Reserve_Capacity
              (2 * (Found.Relations.Length + Ada.Containers.Count_Type (Records.Field_Count (From))));
         end if;
         for Index in 1 .. Records.Field_Count (From) loop
            declare
               Field : constant String := Records.Field_Name (From, Index);
               Text  : constant String := Records.Field_Value (From, Index);
            begin
               if Field'Length > 9 and then Field (Field'First .. Field'First + 8) = "relation." then
                  declare
                     --  Where each of its six or seven parts begins and
                     --  ends; an eighth makes it no relation, as before.
                     First, Last : array (1 .. 8) of Natural := [others => 0];
                     Count : Natural := 0;
                     Start : Positive := Text'First;
                  begin
                     for At_Char in Text'First .. Text'Last + 1 loop
                        if At_Char > Text'Last or else Text (At_Char) = Tab then
                           Count := Count + 1;
                           First (Count) := Start;
                           Last (Count) := At_Char - 1;
                           Start := At_Char + 1;
                           exit when Count = 8;
                        end if;
                     end loop;
                     if Count in 6 .. 7 then
                        Found.Relations.Append
                          (Relation'
                           (Kind   => Relation_Kind'Value (Text (First (1) .. Last (1))),
                            From   => Again (Last_From, Text (First (2) .. Last (2))),
                            To     => Shared (Names, Text (First (3) .. Last (3))),
                            Source => Derivation'Value (Text (First (4) .. Last (4))),
                            Sure   => Confidence'Value (Text (First (5) .. Last (5))),
                            Where  => To_Unbounded_String (Text (First (6) .. Last (6))),
                            Origin => Again (Last_Origin, (if Count = 7 then Text (First (7) .. Last (7)) else ""))));
                     end if;
                  end;
               else
                  declare
                     Parts : constant Name_Lists.Vector := Split_Tabs (Text);
                  begin
                     if Ada.Strings.Fixed.Index (Field, "file.") = Field'First
                       and then Natural (Parts.Length) in 4 .. 5
                     then
                        Found.Files.Append
                          (File_Entry'
                           (Path        => To_Unbounded_String (Parts (1)),
                            Language    => To_Unbounded_String (Parts (2)),
                            Role        => File_Role'Value (Parts (3)),
                            Fingerprint => To_Unbounded_String (Parts (4)),
                            Stamp       => To_Unbounded_String
                                             (if Natural (Parts.Length) = 5 then Parts (5) else "")));
                     elsif Ada.Strings.Fixed.Index (Field, "symbol.") = Field'First
                       and then Natural (Parts.Length) = 4
                     then
                        Found.Symbols.Append
                          (Symbol'
                           (Name => To_Unbounded_String (Parts (1)),
                            Kind => To_Unbounded_String (Parts (2)),
                            Path => To_Unbounded_String (Parts (3)),
                            Line => Natural'Value (Parts (4))));
                     end if;
                  end;
               end if;
            end;
         end loop;
      end Take;
   begin
      Found := (others => <>);
      Stores.Read (Item, Indexes_Area, Index_Name, Value, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      --  Kept by another way of reading the source: read again, as if
      --  nothing were kept.
      if Records.Get (Value, "reader") /= Reader_Version then
         Status := E.Make (E.Framework_Not_Found);
         E.Add_Text (Status, "name", "the repository's graph as this version reads it");
         return;
      end if;

      Take (Value);
      if Record_Only and then Records.Get (Value, "buckets") /= "" then
         Found.Light := True;
         return;
      end if;
      --  Its relations in buckets: each the one the record lists, by its
      --  print, or the graph is not taken.
      if Records.Get (Value, "buckets") /= "" then
         declare
            Count : constant Positive := Positive'Value (Records.Get (Value, "buckets"));
         begin
            for Bucket in 1 .. Count loop
               if Warming.Stopping then
                  raise Warm_Up_Stopped;
               end if;
               declare
                  Held : Records.Item;
               begin
                  Stores.Read (Item, Indexes_Area, Bucket_Name (Bucket, Count), Held, Status);
                  if E.Is_Ok (Status)
                    and then Records.Get (Held, "fingerprint")
                             /= Records.Get (Value, "bucket." & Records.Numbered (Bucket, Count))
                  then
                     Status := E.Make (E.Framework_Record_Malformed);
                     E.Add_Text (Status, "path", "indexes/" & Bucket_Name (Bucket, Count), E.Param_Path);
                     E.Add_Text (Status, "detail", "a bucket of another graph than the one it is kept with");
                  end if;
                  if E.Is_Error (Status) then
                     Found := (others => <>);
                     return;
                  end if;
                  Take (Held);
               end;
            end loop;
         end;
      end if;
      --  Its relations in parts of their own, as graphs were kept before
      --  buckets: each the same graph's, by its print, or not taken.
      if Records.Get (Value, "parts") /= "" then
         for Part in 1 .. Natural'Value (Records.Get (Value, "parts")) loop
            declare
               Held : Records.Item;
            begin
               Stores.Read (Item, Indexes_Area, Part_Name (Part), Held, Status);
               if E.Is_Ok (Status) and then Records.Get (Held, "fingerprint") /= Records.Get (Value, "fingerprint")
               then
                  Status := E.Make (E.Framework_Record_Malformed);
                  E.Add_Text (Status, "path", "indexes/" & Part_Name (Part), E.Param_Path);
                  E.Add_Text (Status, "detail", "a part of another graph than the one it is kept with");
               end if;
               if E.Is_Error (Status) then
                  Found := (others => <>);
                  return;
               end if;
               Take (Held);
            end;
         end loop;
      end if;
   exception
      when Constraint_Error =>
         Found := (others => <>);
         Status := E.Make (E.Framework_Record_Malformed);
         E.Add_Text (Status, "path", "indexes/" & Index_Name, E.Param_Path);
         E.Add_Text (Status, "detail", "a line of the graph is not one");
   end Load_Kept;

   procedure Load
     (Item   : Stores.Store;
      Found  : out Graph;
      Status : out Model_Runner.Errors.Error_Info)
   is
   begin
      Load_Kept (Item, Found, Status, Record_Only => False);
   end Load;

   procedure Load_Declared
     (Item   : Stores.Store;
      Found  : out Graph;
      Status : out Model_Runner.Errors.Error_Info)
   is
   begin
      Load_Kept (Item, Found, Status, Record_Only => True);
   end Load_Declared;

   -------------------
   -- Patch_Current --
   -------------------

   procedure Patch_Current
     (Item    : in out Stores.Store;
      Found   : out Graph;
      Patched : out Boolean;
      Status  : out Model_Runner.Errors.Error_Info)
   is
      Directory  : constant String := Ada.Directories.Containing_Directory (Stores.Root (Item));
      Value      : Records.Item;
      Light      : Graph;
      Read_Again : Natural;
      Unchanged  : Boolean;
      Change     : Stores.Transaction;

      --  The files with a reference to one of Names: the buckets whose
      --  uses say one of them, read, and their references' files.
      function Referrers (Names : Name_Sets.Set; Known : out Boolean) return Name_Sets.Set
      is (Kept_Referrers (Item, Names, Known));
   begin
      Patched := False;
      Status := E.Success;
      Found := (others => <>);
      Stores.Read (Item, Indexes_Area, Index_Name, Value, Status);
      if E.Is_Error (Status) or else Records.Get (Value, "buckets") = ""
        or else Records.Get (Value, "reader") /= Reader_Version
      then
         Status := E.Success;
         return;
      end if;
      Load_Kept (Item, Light, Status, Record_Only => True);
      if E.Is_Error (Status) then
         Status := E.Success;
         return;
      end if;
      Found := Refresh_Or_Check (Directory, Light, Read_Again, Roots_Of (Item), False, Unchanged,
                                 Referrers'Access);
      if Unchanged then
         Patched := True;
         return;
      end if;
      declare
         Count   : constant Positive := Positive'Value (Records.Get (Value, "buckets"));
         Touched : Name_Sets.Set;
         Struck  : array (1 .. Count) of Boolean := [others => False];
         Main    : Records.Item :=
           Records.Create (Schemas.Repository_Schema, 1, "REPOSITORY",
                           Stores.Current_Revision (Item, Indexes_Area, Index_Name) + 1);
         Declared : Natural := 0;
         Uses     : Records.Item;
         Uses_Read : E.Error_Info;
      begin
         Stores.Read (Item, Indexes_Area, Uses_Name, Uses, Uses_Read);
         for Path of Found.Touched loop
            Touched.Include (Path);
            declare
               Probe : Relation;
            begin
               Probe.Origin := To_Unbounded_String (Path);
               Struck (Bucket_Of (Probe, Count)) := True;
            end;
         end loop;

         --  Each bucket a touched file falls in: its references kept but
         --  for the touched files', and theirs as read now.
         for Bucket in 1 .. Count loop
            declare
               Field : constant String := "bucket." & Records.Numbered (Bucket, Count);
            begin
               if Struck (Bucket) then
                  declare
                     Held  : Records.Item;
                     Lines : Name_Lists.Vector;
                     Print : Interfaces.Unsigned_64 := Hash ("");
                     Bytes : Long_Long_Integer := 0;
                  begin
                     Stores.Read (Item, Indexes_Area, Bucket_Name (Bucket, Count), Held, Status);
                     if E.Is_Error (Status) or else Records.Get (Held, "fingerprint") /= Records.Get (Value, Field) then
                        Status := E.Success;
                        return;
                     end if;
                     for Index in 1 .. Records.Field_Count (Held) loop
                        declare
                           Name : constant String := Records.Field_Name (Held, Index);
                           Text : constant String := Records.Field_Value (Held, Index);
                           Tab_At : constant Natural := Ada.Strings.Fixed.Index (Text, [Tab], Ada.Strings.Backward);
                        begin
                           if Name'Length > 9 and then Name (Name'First .. Name'First + 8) = "relation."
                             and then not Touched.Contains (Text (Tab_At + 1 .. Text'Last))
                           then
                              Lines.Append (Text);
                           end if;
                        end;
                     end loop;
                     for Link of Found.Relations loop
                        if Is_Reference (Link.Kind) and then Touched.Contains (To_String (Link.Origin))
                          and then Bucket_Of (Link, Count) = Bucket
                        then
                           Lines.Append (Relation_Text (Link));
                        end if;
                     end loop;
                     for Line of Lines loop
                        Print := Hash_On (Line & ASCII.LF, Print);
                        Bytes := Bytes + Long_Long_Integer (Line'Length + Field_Bytes);
                     end loop;
                     --  Past what a bucket holds: the whole graph is kept
                     --  again, in more of them.
                     if Bytes > Part_Bytes then
                        return;
                     end if;
                     declare
                        Kept : Records.Item :=
                          Records.Create
                            (Schemas.Repository_Schema, 1, "REPOSITORY-BUCKET-" & Records.Numbered (Bucket, Count),
                             Stores.Current_Revision (Item, Indexes_Area, Bucket_Name (Bucket, Count)) + 1);
                     begin
                        Records.Set (Kept, "fingerprint", Fingerprint_Of (Print));
                        Records.Set (Kept, "reader", Reader_Version);
                        for Index in 1 .. Natural (Lines.Length) loop
                           Records.Set (Kept, "relation." & Records.Numbered (Index, Natural (Lines.Length)),
                                        Lines (Index));
                        end loop;
                        Stores.Put (Change, Indexes_Area, Bucket_Name (Bucket, Count), Kept);
                     end;
                     Records.Set (Main, Field, Fingerprint_Of (Print));
                     if E.Is_Ok (Uses_Read) then
                        Records.Set (Uses, Field, Names_Said (Lines));
                     end if;
                  end;
               else
                  Records.Set (Main, Field, Records.Get (Value, Field));
               end if;
            end;
         end loop;

         --  The record: buckets, files, fingerprint, reader, what the files
         --  declare, symbols -- in the order it keeps its fields.
         Records.Set (Main, "buckets", Image (Count));
         for Index in 1 .. Natural (Found.Files.Length) loop
            declare
               File : File_Entry renames Found.Files (Index);
            begin
               Records.Set
                 (Main, "file." & Records.Numbered (Index, Natural (Found.Files.Length)),
                  To_String (File.Path) & Tab & To_String (File.Language) & Tab
                  & Lower (File_Role'Image (File.Role)) & Tab
                  & To_String (File.Fingerprint) & Tab & To_String (File.Stamp));
            end;
         end loop;
         Records.Set (Main, "fingerprint", Graph_Fingerprint (Found));
         Records.Set (Main, "reader", Reader_Version);
         for Link of Found.Relations loop
            if not Is_Reference (Link.Kind) then
               Declared := Declared + 1;
            end if;
         end loop;
         declare
            Shown : Natural := 0;
         begin
            for Link of Found.Relations loop
               if not Is_Reference (Link.Kind) then
                  Shown := Shown + 1;
                  Records.Set (Main, "relation." & Records.Numbered (Shown, Declared), Relation_Text (Link));
               end if;
            end loop;
         end;
         for Index in 1 .. Natural (Found.Symbols.Length) loop
            declare
               Named : Symbol renames Found.Symbols (Index);
            begin
               Records.Set
                 (Main, "symbol." & Records.Numbered (Index, Natural (Found.Symbols.Length)),
                  To_String (Named.Name) & Tab & To_String (Named.Kind) & Tab
                  & To_String (Named.Path) & Tab & Image (Named.Line));
            end;
         end loop;
         Stores.Put (Change, Indexes_Area, Index_Name, Main);
         if E.Is_Ok (Uses_Read) then
            Records.Set (Uses, "fingerprint", Graph_Fingerprint (Found));
            Records.Set_Revision (Uses, Records.Revision (Uses) + 1);
            Stores.Put (Change, Indexes_Area, Uses_Name, Uses);
         end if;
         Stores.Commit (Item, Change, Status);
         Patched := E.Is_Ok (Status);
         --  What the state keeps now, held without its references.
         if Patched then
            Remember (Key_Of (Item), Found, Graph_Fingerprint (Found));
         end if;
      end;
   exception
      when Constraint_Error =>
         Patched := False;
         Status := E.Success;
   end Patch_Current;

   ---------------------------------------------------------------------------
   --  Extents.
   ---------------------------------------------------------------------------

   --  The text's lines, each without its end.
   function Text_Lines (Text : String) return Name_Lists.Vector is
      Result : Name_Lists.Vector;
      Start  : Positive := Text'First;
   begin
      for Index in Text'Range loop
         if Text (Index) = ASCII.LF then
            Result.Append
              (Text (Start .. (if Index > Start and then Text (Index - 1) = ASCII.CR then Index - 2
                               else Index - 1)));
            Start := Index + 1;
         end if;
      end loop;
      if Start <= Text'Last then
         Result.Append (Text (Start .. Text'Last));
      end if;
      return Result;
   end Text_Lines;

   --  A line's text with its leading blanks taken off.
   function Unindented (Line : String) return String
   is (Ada.Strings.Fixed.Trim (Line, Ada.Strings.Left));

   --  How far a line is indented, a tab as one.
   function Indent_Of (Line : String) return Natural is
   begin
      for Index in Line'Range loop
         if Line (Index) not in ' ' | ASCII.HT then
            return Index - Line'First;
         end if;
      end loop;
      return Line'Length;
   end Indent_Of;

   --  First moved up over the comment lines just above it -- what a
   --  declaration says of itself -- as far as a blank line.
   function With_Comments
     (Lines : Name_Lists.Vector; First : Positive; Marks : String) return Positive
   is
      Result : Positive := First;
   begin
      while Result > 1 and then First - Result < 40 loop
         declare
            Above : constant String := Unindented (Lines (Result - 1));
         begin
            exit when Above'Length = 0
              or else not (for some Mark of Name_Lists.Vector'(Split (Marks)) =>
                             Above'Length >= Mark'Length
                             and then Above (Above'First .. Above'First + Mark'Length - 1) = Mark);
         end;
         Result := Result - 1;
      end loop;
      return Result;
   end With_Comments;

   --  An Ada declaration's lines, by the tokens a scan reads.
   function Ada_Extent (Tokens : Token_Vectors.Vector; Line : Positive) return Extent is
      Count  : constant Natural := Natural (Tokens.Length);
      Start  : Natural := 0;
      Key    : Natural := 0;
      Opener : Natural;
      Result : Extent;

      function Spelled (Index : Positive) return String
      is (if Tokens (Index).Kind = Word then Lower (To_String (Tokens (Index).Text)) else "");

      function Declares (Index : Positive) return Boolean
      is (Spelled (Index) in "procedure" | "function" | "package" | "type" | "subtype" | "task"
                             | "protected" | "entry");

      --  The first ; at no depth of brackets or records from a token.
      function Semicolon_From (From : Positive) return Natural is
         Brackets : Integer := 0;
         Records  : Integer := 0;
      begin
         for Ahead in From .. Count loop
            if Is_Mark (Tokens (Ahead), '(') then
               Brackets := Brackets + 1;
            elsif Is_Mark (Tokens (Ahead), ')') then
               Brackets := Brackets - 1;
            elsif Spelled (Ahead) = "record"
              and then not (Ahead > 1 and then (Is_Word (Tokens (Ahead - 1), "null")
                                                or else Is_Word (Tokens (Ahead - 1), "end")))
            then
               Records := Records + 1;
            elsif Spelled (Ahead) = "end" and then Ahead < Count and then Is_Word (Tokens (Ahead + 1), "record")
            then
               Records := Records - 1;
            elsif Brackets <= 0 and then Records <= 0 and then Is_Mark (Tokens (Ahead), ';') then
               return Ahead;
            end if;
         end loop;
         return 0;
      end Semicolon_From;

      --  The ; of the first end NAME; after a token, NAME dotted or not.
      function End_Of (Name : String; From : Positive) return Natural is
         Wanted : constant String := Lower (Name);
         Named  : Unbounded_String;
         Next   : Positive;
      begin
         for Ahead in From .. Count - 2 loop
            if Is_Word (Tokens (Ahead), "end") then
               if Tokens (Ahead + 1).Kind = Text_Literal then
                  if Lower (To_String (Tokens (Ahead + 1).Text)) = Wanted
                    and then Is_Mark (Tokens (Ahead + 2), ';')
                  then
                     return Ahead + 2;
                  end if;
               else
                  Name_At (Tokens, Ahead + 1, Named, Next);
                  if Lower (To_String (Named)) = Wanted and then Next <= Count
                    and then Is_Mark (Tokens (Next), ';')
                  then
                     return Next;
                  end if;
               end if;
            end if;
         end loop;
         return 0;
      end End_Of;

      --  The name a declaring word gives, past body and type.
      function Name_After (Index : Positive) return String is
         At_Name : Positive := Index + 1;
         Named   : Unbounded_String;
         Next    : Positive;
      begin
         if At_Name <= Count and then Spelled (At_Name) in "body" | "type" then
            At_Name := At_Name + 1;
         end if;
         if At_Name > Count then
            return "";
         elsif Tokens (At_Name).Kind = Text_Literal then
            return To_String (Tokens (At_Name).Text);
         end if;
         Name_At (Tokens, At_Name, Named, Next);
         return To_String (Named);
      end Name_After;

      Stop : Natural := 0;
   begin
      for Index in 1 .. Count loop
         if Tokens (Index).Line >= Line then
            Start := Index;
            exit;
         end if;
      end loop;
      if Start = 0 or else Tokens (Start).Line /= Line then
         return Result;
      end if;

      --  The declaring word: the line's first, or one just before the name
      --  the line starts with -- procedure on one line and its name on the
      --  next.
      if Declares (Start) then
         Key := Start;
      else
         for Back in reverse Natural'Max (1, Start - 3) .. Start - 1 loop
            exit when Is_Mark (Tokens (Back), ';');
            if Declares (Back) then
               Key := Back;
               exit;
            end if;
         end loop;
         if Key = 0 then
            Key := Start;
         end if;
      end if;

      --  Where it starts: overriding, or not overriding, before it; a
      --  generic's formal part before that -- walked back to generic, and
      --  stopped at what ends or opens anything else.
      Opener := Key;
      if Opener > 1 and then Is_Word (Tokens (Opener - 1), "overriding") then
         Opener := Opener - 1;
         if Opener > 1 and then Is_Word (Tokens (Opener - 1), "not") then
            Opener := Opener - 1;
         end if;
      end if;
      if Spelled (Key) in "procedure" | "function" | "package" then
         for Back in reverse Natural'Max (1, Opener - 2_000) .. Opener - 1 loop
            declare
               Word_Text : constant String := Spelled (Back);
            begin
               if Word_Text = "generic" then
                  Opener := Back;
                  exit;
               end if;
               exit when Word_Text in "end" | "begin"
                 or else (Word_Text in "procedure" | "function" | "package"
                          and then not (Back > 1 and then Is_Word (Tokens (Back - 1), "with")));
            end;
         end loop;
      end if;

      declare
         Kind : constant String := Spelled (Key);
         Name : constant String := (if Declares (Key) then Name_After (Key) else "");
      begin
         if Kind in "procedure" | "function" | "entry" then
            --  Its header ends at is, or at ; where it is only declared.
            declare
               Brackets : Integer := 0;
               Header   : Natural := 0;
            begin
               for Ahead in Key + 1 .. Count loop
                  if Is_Mark (Tokens (Ahead), '(') then
                     Brackets := Brackets + 1;
                  elsif Is_Mark (Tokens (Ahead), ')') then
                     Brackets := Brackets - 1;
                  elsif Brackets = 0
                    and then (Is_Mark (Tokens (Ahead), ';') or else Is_Word (Tokens (Ahead), "is"))
                  then
                     Header := Ahead;
                     exit;
                  end if;
               end loop;
               if Header = 0 then
                  Stop := 0;
               elsif Is_Mark (Tokens (Header), ';') then
                  Stop := Header;
               elsif Header < Count
                 and then (Spelled (Header + 1) in "new" | "abstract" | "null" | "separate"
                           or else Is_Mark (Tokens (Header + 1), '('))
               then
                  --  An instance, an abstract or null one, a separate body,
                  --  an expression function: to its ;.
                  Stop := Semicolon_From (Header + 1);
               else
                  Stop := End_Of (Name, Header + 1);
               end if;
            end;
         elsif Kind in "package" | "task" | "protected" then
            declare
               Brackets : Integer := 0;
               Header   : Natural := 0;
            begin
               for Ahead in Key + 1 .. Count loop
                  if Is_Mark (Tokens (Ahead), '(') then
                     Brackets := Brackets + 1;
                  elsif Is_Mark (Tokens (Ahead), ')') then
                     Brackets := Brackets - 1;
                  elsif Brackets = 0
                    and then (Is_Mark (Tokens (Ahead), ';') or else Is_Word (Tokens (Ahead), "is"))
                  then
                     Header := Ahead;
                     exit;
                  end if;
               end loop;
               if Header = 0 then
                  Stop := 0;
               elsif Is_Mark (Tokens (Header), ';') then
                  Stop := Header;
               elsif Header < Count and then Spelled (Header + 1) in "new" | "separate" then
                  Stop := Semicolon_From (Header + 1);
               else
                  Stop := End_Of (Name, Header + 1);
               end if;
            end;
         else
            --  A type, a subtype, a constant, an exception, a literal: to
            --  the ; that ends it, past its record and its brackets.
            Stop := Semicolon_From (Key);
         end if;
      end;

      Result.First := Tokens (Opener).Line;
      if Stop > 0 then
         Result.Last := Tokens (Stop).Line;
         Result.Structural := True;
      end if;
      return Result;
   end Ada_Extent;

   --  A declaration's lines by its braces: from its line to the ; that
   --  ends a declaration without a body, or to the brace that closes the
   --  first it opens; strings, characters and comments not counted.
   function Brace_Extent (Lines : Name_Lists.Vector; Line : Positive) return Extent is
      Result   : Extent := (First => Line, Last => 0, Structural => False);
      Depth    : Natural := 0;
      Brackets : Integer := 0;
      Opened   : Boolean := False;
      In_Block : Boolean := False;
   begin
      for Row in Line .. Natural (Lines.Length) loop
         declare
            Text  : constant String := Lines (Row);
            Index : Natural := Text'First;
         begin
            while Index <= Text'Last loop
               declare
                  Char : constant Character := Text (Index);
               begin
                  if In_Block then
                     if Char = '*' and then Index < Text'Last and then Text (Index + 1) = '/' then
                        In_Block := False;
                        Index := Index + 1;
                     end if;
                  elsif Char = '/' and then Index < Text'Last and then Text (Index + 1) = '/' then
                     exit;
                  elsif Char = '/' and then Index < Text'Last and then Text (Index + 1) = '*' then
                     In_Block := True;
                     Index := Index + 1;
                  elsif Char = '"' then
                     Index := Index + 1;
                     while Index <= Text'Last and then Text (Index) /= '"' loop
                        if Text (Index) = '\' then
                           Index := Index + 1;
                        end if;
                        Index := Index + 1;
                     end loop;
                  elsif Char = ''' and then Index + 2 <= Text'Last
                    and then (Text (Index + 2) = ''' or else Text (Index + 1) = '\')
                  then
                     Index := Index + (if Text (Index + 1) = '\' then 3 else 2);
                  elsif Char = '(' then
                     Brackets := Brackets + 1;
                  elsif Char = ')' then
                     Brackets := Brackets - 1;
                  elsif Char = '{' then
                     Depth := Depth + 1;
                     Opened := True;
                  elsif Char = '}' and then Depth > 0 then
                     Depth := Depth - 1;
                     if Opened and then Depth = 0 then
                        Result.Last := Row;
                        Result.Structural := True;
                        return Result;
                     end if;
                  elsif Char = ';' and then not Opened and then Brackets <= 0 then
                     Result.Last := Row;
                     Result.Structural := True;
                     return Result;
                  end if;
               end;
               Index := Index + 1;
            end loop;
         end;
      end loop;
      return Result;
   end Brace_Extent;

   --  A Python definition's lines: its header, and every line after it
   --  indented further, blank lines among them, up to the last such.
   function Indent_Extent (Lines : Name_Lists.Vector; Line : Positive) return Extent is
      Header : constant Natural := Indent_Of (Lines (Line));
      Result : Extent := (First => Line, Last => Line, Structural => True);
      Row    : Positive := Line;
   begin
      --  A header over several lines: to the one ending in its colon.
      while Row < Natural (Lines.Length)
        and then Ada.Strings.Fixed.Index (Ada.Strings.Fixed.Trim (Lines (Row), Ada.Strings.Right), ":",
                                          Ada.Strings.Backward)
                 /= Ada.Strings.Fixed.Trim (Lines (Row), Ada.Strings.Right)'Last
      loop
         exit when Row - Line > 20;
         Row := Row + 1;
      end loop;
      Result.Last := Row;
      for Next in Row + 1 .. Natural (Lines.Length) loop
         if Unindented (Lines (Next))'Length > 0 then
            exit when Indent_Of (Lines (Next)) <= Header;
            Result.Last := Next;
         end if;
      end loop;
      return Result;
   end Indent_Extent;

   ---------------
   -- Extent_Of --
   ---------------

   --  As Extent_Of, of a text already parted into lines and, for Ada,
   --  into tokens: what Enclosing asks of every symbol of one file.
   function Extent_In
     (Language : String;
      Lines    : Name_Lists.Vector;
      Tokens   : Token_Vectors.Vector;
      Line     : Positive;
      Most     : Positive) return Extent
   is
      Result : Extent;
   begin
      if Line > Natural (Lines.Length) then
         return Result;
      end if;
      if Language = "Ada" then
         Result := Ada_Extent (Tokens, Line);
         if Result.First > 0 then
            Result.First := With_Comments (Lines, Result.First, "--");
         end if;
      elsif Language = "Python" then
         Result := Indent_Extent (Lines, Line);
         Result.First := With_Comments (Lines, Result.First, "# @");
      elsif Language in "C" | "C++" | "Rust" | "Go" | "Java" | "JavaScript" | "TypeScript" | "C#"
                      | "Kotlin" | "Swift" | "Zig"
      then
         Result := Brace_Extent (Lines, Line);
         Result.First := With_Comments (Lines, Result.First, "// /* * #[");
      end if;
      if Result.First = 0 then
         Result.First := Line;
      end if;
      if not Result.Structural then
         Result.Last := Natural'Min (Natural (Lines.Length), Line + Most - 1);
      end if;
      return Result;
   end Extent_In;

   function Extent_Of
     (Path : String;
      Text : String;
      Line : Positive;
      Most : Positive := 40) return Extent
   is
      Language : constant String := Language_Of (Path);
   begin
      return Extent_In
        (Language, Text_Lines (Text),
         (if Language = "Ada" then Tokens_Of (Text) else Token_Vectors.Empty_Vector), Line, Most);
   end Extent_Of;

   --------------------
   -- Declared_Lines --
   --------------------

   function Declared_Lines (Text, Name : String) return Name_Lists.Vector is
      Tokens : constant Token_Vectors.Vector := Tokens_Of (Text);
      Wanted : constant String := Lower (Name);
      Result : Name_Lists.Vector;
   begin
      for Index in 1 .. Natural (Tokens.Length) - 1 loop
         if Tokens (Index).Kind = Word
           and then Lower (To_String (Tokens (Index).Text)) in "procedure" | "function" | "entry" | "package"
                                                              | "task" | "protected"
           and then not (Index > 1 and then (Is_Word (Tokens (Index - 1), "with")
                                             or else Is_Word (Tokens (Index - 1), "access")
                                             or else Is_Word (Tokens (Index - 1), "end")))
         then
            declare
               At_Name : Positive := Index + 1;
            begin
               if At_Name < Natural (Tokens.Length)
                 and then (Is_Word (Tokens (At_Name), "body") or else Is_Word (Tokens (At_Name), "type"))
               then
                  At_Name := At_Name + 1;
               end if;
               if Lower (To_String (Tokens (At_Name).Text)) = Wanted
                 and then not Result.Contains (Image (Tokens (Index).Line))
               then
                  Result.Append (Image (Tokens (Index).Line));
               end if;
            end;
         end if;
      end loop;
      return Result;
   end Declared_Lines;

   --------------
   -- Read_One --
   --------------

   function Read_One (Path, Text : String) return Graph is
      Result : Graph;
   begin
      Result.Reading := To_Unbounded_String (Path);
      Languages.Adapter_For (Language_Of (Path)).Read (Path, Text, Result);
      return Result;
   end Read_One;

   ---------------
   -- Enclosing --
   ---------------

   function Enclosing
     (Path : String;
      Text : String;
      Line : Positive;
      Name : out Unbounded_String) return Extent
   is
      Own      : constant Graph := Read_One (Path, Text);
      Language : constant String := Language_Of (Path);
      Lines    : constant Name_Lists.Vector := Text_Lines (Text);
      Tokens   : constant Token_Vectors.Vector :=
        (if Language = "Ada" then Tokens_Of (Text) else Token_Vectors.Empty_Vector);
      Best     : Extent;
      Count    : constant Natural := Natural (Lines.Length);
   begin
      Name := Null_Unbounded_String;

      --  Ada's from its tokens: every body and nested unit, not only those
      --  the graph names, so a use is shown in the subprogram it is in and
      --  not in the whole of the one around that.
      if Language = "Ada" then
         declare
            Unit : constant String := Unit_Of (Tokens);
         begin
            for Index in 1 .. Natural (Tokens.Length) loop
               exit when Tokens (Index).Line > Line;
               if Tokens (Index).Kind = Word
                 and then Lower (To_String (Tokens (Index).Text)) in "procedure" | "function" | "entry" | "package"
                                                                    | "task" | "protected"
                 and then not (Index > 1 and then (Is_Word (Tokens (Index - 1), "with")
                                                   or else Is_Word (Tokens (Index - 1), "access")))
                 and then Index < Natural (Tokens.Length)
                 and then (Index = 1 or else Tokens (Index - 1).Line < Tokens (Index).Line
                           or else Is_Word (Tokens (Index - 1), "overriding"))
               then
                  declare
                     Held : constant Extent := Extent_In (Language, Lines, Tokens, Tokens (Index).Line, 40);
                     At_Name : Positive := Index + 1;
                  begin
                     if Held.Structural and then Held.First <= Line and then Held.Last >= Line
                       and then (Best.First = 0 or else Held.First >= Best.First)
                     then
                        Best := Held;
                        if At_Name < Natural (Tokens.Length)
                          and then (Is_Word (Tokens (At_Name), "body") or else Is_Word (Tokens (At_Name), "type"))
                        then
                           At_Name := At_Name + 1;
                        end if;
                        declare
                           Dotted  : Unbounded_String;
                           Past    : Positive;
                        begin
                           Name_At (Tokens, At_Name, Dotted, Past);
                           if Dotted = Null_Unbounded_String then
                              Dotted := Tokens (At_Name).Text;
                           end if;
                           declare
                              Spelled : constant String := To_String (Dotted);
                           begin
                              Name := To_Unbounded_String
                                (if Lower (Spelled) = Lower (Unit) or else Unit = "" then Spelled
                                 else Unit & "." & Spelled);
                           end;
                        end;
                     end if;
                  end;
               end if;
            end loop;
         end;
         if Best.First > 0 then
            return Best;
         end if;
      end if;

      for Item of Own.Symbols loop
         if Item.Line in 1 .. Line then
            declare
               Held : constant Extent := Extent_In (Language, Lines, Tokens, Item.Line, 40);
            begin
               if Held.Structural and then Held.First <= Line and then Held.Last >= Line
                 and then (Best.First = 0 or else Held.First >= Best.First)
               then
                  Best := Held;
                  Name := Item.Name;
               end if;
            end;
         end if;
      end loop;
      if Best.First = 0 and then Line <= Count then
         Best := (First => Natural'Max (1, Line - 8), Last => Natural'Min (Count, Line + 8), Structural => False);
      end if;
      return Best;
   end Enclosing;

   ---------------------------------------------------------------------------
   --  Queries.
   ---------------------------------------------------------------------------

   ------------------
   -- Find_Symbols --
   ------------------

   function Find_Symbols (From : Graph; Name : String) return Name_Lists.Vector
   is
      Wanted_As : constant String := Name;
      Result : Name_Lists.Vector;
   begin
      for Item of From.Symbols loop
         declare
            --  Ada's names are the same in any case; other languages'
            --  are not: Charset is not charset.
            Folds  : constant Boolean := Language_Of (To_String (Item.Path)) = "Ada";
            Full   : constant String :=
              (if Folds then Lower (To_String (Item.Name)) else To_String (Item.Name));
            Wanted : constant String := (if Folds then Lower (Wanted_As) else Wanted_As);
         begin
            if (Full = Wanted
                or else (Full'Length > Wanted'Length
                         and then Full (Full'Last - Wanted'Length .. Full'Last)
                                  = "." & Wanted)
                --  Rust's paths: crate::fnv::fnv1a is fnv1a, and fnv::fnv1a.
                or else (Full'Length > Wanted'Length + 1
                         and then Full (Full'Last - Wanted'Length - 1 .. Full'Last)
                                  = "::" & Wanted))
              and then not Result.Contains (To_String (Item.Name))
            then
               Result.Append (To_String (Item.Name));
            end if;
         end;
      end loop;
      return Sorted (Result);
   end Find_Symbols;

   ---------------
   -- Symbol_Of --
   ---------------

   function Symbol_Of
     (From  : Graph;
      Name  : String;
      Found : out Boolean) return Symbol is
   begin
      for Item of From.Symbols loop
         if To_String (Item.Name) = Name then
            Found := True;
            return Item;
         end if;
      end loop;
      Found := False;
      return (others => <>);
   end Symbol_Of;

   -------------------
   -- References_To --
   -------------------

   function References_To
     (From : Graph;
      Name : String) return Name_Lists.Vector
   is
      Result : Name_Lists.Vector;
   begin
      for Link of From.Relations loop
         if Link.Kind = References and then To_String (Link.To) = Name
           and then not Result.Contains (To_String (Link.Where))
         then
            Result.Append (To_String (Link.Where));
         end if;
      end loop;
      return Sorted (Result);
   end References_To;

   function References_To
     (Item : Stores.Store;
      From : Graph;
      Name : String) return Name_Lists.Vector
   is
      function Asked (Said : String) return Boolean is (Said = Name);
      Result : Name_Lists.Vector;
   begin
      for Link of Uses_Of (Item, From, Asked'Access) loop
         if Link.Kind = References and then not Result.Contains (To_String (Link.Where)) then
            Result.Append (To_String (Link.Where));
         end if;
      end loop;
      return Sorted (Result);
   end References_To;

   ---------------------
   -- Dependencies_Of --
   ---------------------

   function Dependencies_Of
     (From : Graph;
      Unit : String) return Name_Lists.Vector
   is
      Result : Name_Lists.Vector;
   begin
      for Link of From.Relations loop
         if Link.Kind = Depends_On
           and then Lower (To_String (Link.From)) = Lower (Unit)
           and then not Result.Contains (To_String (Link.To))
         then
            Result.Append (To_String (Link.To));
         end if;
      end loop;
      return Sorted (Result);
   end Dependencies_Of;

   -------------------
   -- Dependents_Of --
   -------------------

   function Dependents_Of
     (From : Graph;
      Unit : String) return Name_Lists.Vector
   is
      Result : Name_Lists.Vector;
   begin
      for Link of From.Relations loop
         if Link.Kind = Depends_On
           and then Lower (To_String (Link.To)) = Lower (Unit)
           --  A unit is not its own user: a C body including its header.
           and then Lower (To_String (Link.From)) /= Lower (Unit)
           and then not Result.Contains (To_String (Link.From))
         then
            Result.Append (To_String (Link.From));
         end if;
      end loop;
      return Sorted (Result);
   end Dependents_Of;

   ------------
   -- Warmer --
   ------------

   task body Warmer is
      Directory : Unbounded_String;
      Action    : After_Warm_Up;
   begin
      loop
         select
            accept Take (Project_Directory : String; Then_Warm : After_Warm_Up) do
               Directory := To_Unbounded_String (Project_Directory);
               Action := Then_Warm;
            end Take;
         or
            terminate;
         end select;
         declare
            Store    : Stores.Store;
            Status   : E.Error_Info;
            --  Let go once: a read claimed after it is another's.
            Released : Boolean := False;
         begin
            Stores.Open_To_Read (Store, To_String (Directory), Status);
            if E.Is_Ok (Status) then
               declare
                  Found : constant Graph := Now (Store);
               begin
                  --  The graph's askers let go first: what follows is made
                  --  beside them, not waited for.
                  Warming.Release;
                  Released := True;
                  if Action /= null and then not Warming.Stopping then
                     Action (Store, Found);
                  end if;
               end;
            end if;
            Stores.Close (Store);
            if not Released then
               Warming.Release;
            end if;
         exception
            --  Told to stop, or the read failed: nothing is kept, and what
            --  asks next reads the graph itself.
            when others =>
               begin
                  Stores.Close (Store);
               exception
                  when others =>
                     null;
               end;
               if not Released then
                  Warming.Release;
               end if;
         end;
      end loop;
   end Warmer;

   -------------
   -- Warm_Up --
   -------------

   procedure Warm_Up (Project_Directory : String; Then_Warm : After_Warm_Up := null) is
      Store  : Stores.Store;
      Status : E.Error_Info;
      Key    : Unbounded_String;
      Got    : Boolean;
   begin
      Stores.Open_To_Read (Store, Project_Directory, Status);
      if E.Is_Error (Status) then
         Stores.Close (Store);
         return;
      end if;
      Key := To_Unbounded_String (Key_Of (Store));
      Stores.Close (Store);
      Warming.Claim (To_String (Key), Got);
      if Got then
         select
            Warmer.Take (Project_Directory, Then_Warm);
         or
            delay 1.0;
            Warming.Release;
         end select;
      end if;
   exception
      when others =>
         null;
   end Warm_Up;

end Model_Runner.Framework.Repository;
