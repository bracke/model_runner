with Ada.Characters.Handling;
with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Hostkit.Fs;

with Model_Runner.Errors;
with Model_Runner.Framework.Configurations;
with Model_Runner.Framework.Derivations;
with Model_Runner.Framework.Files;
with Model_Runner.Framework.Observations;
with Model_Runner.Framework.Records;

package body Model_Runner.Framework.Views is

   package E renames Model_Runner.Errors;
   package Obs renames Model_Runner.Framework.Observations;
   use Ada.Strings.Unbounded;
   use type Obs.Applicability;
   use type Obs.Lifecycle;

   LF  : constant Character := ASCII.LF;
   Tab : constant Character := ASCII.HT;
   Dash : constant String := Character'Val (16#E2#) & Character'Val (16#80#) & Character'Val (16#94#);

   function Lower (Text : String) return String
   renames Ada.Characters.Handling.To_Lower;

   function Image (Value : Natural) return String
   is (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   function Scalar (Item : Stores.Store; Name : String) return String is
   begin
      return Records.Get (Configurations.Required (Item), "scalar." & Name);
   exception
      when Configurations.Configuration_Unavailable =>
         return "";
   end Scalar;

   --  The longest run of backticks in a text: what a fence or a code span
   --  around it has to be longer than.
   function Ticks (Text : String) return Natural is
      Most, Run : Natural := 0;
   begin
      for Char of Text loop
         Run := (if Char = '`' then Run + 1 else 0);
         Most := Natural'Max (Most, Run);
      end loop;
      return Most;
   end Ticks;

   --  A text as code within a line: its line ends made spaces, and between
   --  more backticks than it holds, so nothing in it is read as Markdown.
   function Code (Text : String) return String is
      Flat : String := Text;
   begin
      for Char of Flat loop
         if Char in LF | ASCII.CR | Tab then
            Char := ' ';
         end if;
      end loop;
      declare
         Fence : constant String (1 .. Ticks (Flat) + 1) := [others => '`'];
         Pad   : constant String := (if Fence'Length > 1 then " " else "");
      begin
         return Fence & Pad & Flat & Pad & Fence;
      end;
   end Code;

   --  Names as code, comma-separated.
   function Codes (Names : Name_Lists.Vector) return String is
      Text : Unbounded_String;
   begin
      for Name of Names loop
         Append (Text, (if Length (Text) > 0 then ", " else "") & Code (Name));
      end loop;
      return To_String (Text);
   end Codes;

   --  What a page says first: that it is generated, from what, and that it
   --  is not authoritative.
   function Heading (Title, Area_Name, Rest : String) return String
   is ("<!-- " & Generated_Mark & " -->" & LF
       & "# " & Title & LF & LF
       & "**" & Generated_Mark & ".** Made from `" & State_Directory & "/" & Area_Name
       & "`, and made again whenever the project changes; editing it changes nothing. "
       & Rest & LF);

   ----------------------
   -- Observations_Page --
   ----------------------

   function Observations_Page (Item : Stores.Store) return String is
      Text    : Unbounded_String;
      Active  : Unbounded_String;
      Other   : Unbounded_String;
      Counted : Natural := 0;
      Live    : Natural := 0;
      Applies : Natural := 0;
      Unread  : Natural := 0;

      procedure Line (Into : in out Unbounded_String; Label, Value : String) is
      begin
         if Value /= "" then
            Append (Into, "- " & Label & ": " & Value & LF);
         end if;
      end Line;

      procedure Section (Value : Obs.Observation; Into : in out Unbounded_String) is
         Why      : Unbounded_String;
         Standing : constant Obs.Applicability := Obs.Applicability_Of (Item, Value, Why);
         Summary  : constant String := To_String (Value.Summary);
         Fence    : constant String (1 .. Natural'Max (3, Ticks (Summary) + 1)) := [others => '`'];
      begin
         Append (Into, LF & "## " & To_String (Value.Id) & " " & Dash & " " & Obs.Word (Value.Kind) & ", "
                 & Obs.Word (Standing) & LF & LF);
         if Length (Value.Retired) > 0 then
            Append (Into, "Its text was let go: " & To_String (Value.Retired) & "." & LF & LF);
         else
            Append (Into, Fence & "text" & LF & Summary & LF & Fence & LF & LF);
         end if;
         if Why /= "" then
            Line (Into, "standing", Obs.Word (Standing) & " " & Dash & " " & To_String (Why));
         end if;
         Line (Into, "state", Obs.Word (Value.Status));
         Line (Into, "seen", (if Value.Occurrences = 1 then "once" else Image (Value.Occurrences) & " times")
               & ", first " & To_String (Value.Created_At)
               & (if Value.Seen_At /= Value.Created_At then ", last " & To_String (Value.Seen_At) else ""));
         Line (Into, "from",
               Lower (Obs.Producer_Kind'Image (Value.Producer)) & ", "
               & Lower (Obs.Grounding'Image (Value.Ground))
               & (if Length (Value.Task_Id) > 0 then ", task " & Code (To_String (Value.Task_Id)) else "")
               & (if Length (Value.Generation) > 0 then " generation " & To_String (Value.Generation) else "")
               & (if Length (Value.Agent) > 0 then ", agent " & Code (To_String (Value.Agent)) else "")
               & (if Length (Value.Invocation) > 0 then ", invocation " & Code (To_String (Value.Invocation))
                  else ""));
         Line (Into, "component", (if Length (Value.Component) > 0 then Code (To_String (Value.Component))
                                   else ""));
         Line (Into, "files", Codes (Value.Files));
         Line (Into, "symbols", Codes (Value.Symbols));
         Line (Into, "evidence", Codes (Value.Evidence));
         Line (Into, "superseded by", (if Length (Value.Superseded_By) > 0
                                       then Code (To_String (Value.Superseded_By)) else ""));
         Line (Into, "promoted to", (if Length (Value.Promoted_To) > 0
                                     then Code (To_String (Value.Promoted_To)) else ""));
         Line (Into, "similar to", (if Length (Value.Similar_To) > 0
                                    then Code (To_String (Value.Similar_To)) else ""));
         Line (Into, "why", (if Length (Value.Reason) > 0 then Code (To_String (Value.Reason)) else ""));
         if Standing = Obs.Applicable then
            Applies := Applies + 1;
         end if;
      end Section;
   begin
      for Id of Obs.List (Item) loop
         declare
            Value  : Obs.Observation;
            Status : E.Error_Info;
         begin
            Counted := Counted + 1;
            Obs.Read (Item, Id, Value, Status);
            if E.Is_Error (Status) then
               Unread := Unread + 1;
               Append (Other, LF & "## " & Id & " " & Dash & " will not read" & LF);
            elsif Value.Status = Obs.Active then
               Live := Live + 1;
               Section (Value, Active);
            else
               Section (Value, Other);
            end if;
         end;
      end loop;
      Append (Text, Heading ("Observations", Directory_Name (Observations_Area),
                             "What was seen while working, as it was said: an observation satisfies no gate, "
                             & "verifies no requirement and overrides no decision. `/obs` lists, dismisses and "
                             & "promotes them."));
      Append (Text, LF & Image (Counted) & " kept: " & Image (Live) & " active, " & Image (Applies)
              & " of all applying now" & (if Unread > 0 then ", " & Image (Unread) & " that will not read" else "")
              & "." & LF);
      if Length (Active) > 0 then
         Append (Text, LF & "# Active" & LF & To_String (Active));
      end if;
      if Length (Other) > 0 then
         Append (Text, LF & "# No longer active" & LF & To_String (Other));
      end if;
      return To_String (Text);
   end Observations_Page;

   ----------------------
   -- Derivations_Page --
   ----------------------

   function Derivations_Page (Item : Stores.Store) return String is
      Text  : Unbounded_String;
      Lines : constant Name_Lists.Vector := Derivations.Kept (Item);

      --  A table cell: its bars escaped, so a field never splits the row.
      function Cell (Field : String) return String is
         Result : Unbounded_String;
      begin
         for Char of Field loop
            Append (Result, (if Char = '|' then "\|" else [1 => Char]));
         end loop;
         return To_String (Result);
      end Cell;
   begin
      Append (Text, Heading ("Derivations", Directory_Name (Derivations_Area),
                             "A derivation is worked out from what it names and kept to be used again: any of "
                             & "it can be worked out once more, and `/result VER-...` says how a "
                             & "verification's tests were chosen."));
      Append (Text, LF & Image (Natural (Lines.Length)) & " kept." & LF);
      if not Lines.Is_Empty then
         Append (Text, LF & "| Key | Kind | Subject | Algorithm | Made | Answer | Standing |" & LF
                 & "|---|---|---|---|---|---|---|" & LF);
         for One of Lines loop
            Append (Text, "|");
            declare
               First : Positive := One'First;
            begin
               for Index in One'Range loop
                  if One (Index) = Tab then
                     Append (Text, " " & Cell (One (First .. Index - 1)) & " |");
                     First := Index + 1;
                  end if;
               end loop;
               Append (Text, " " & Cell (One (First .. One'Last)) & " |" & LF);
            end;
         end loop;
      end if;
      return To_String (Text);
   end Derivations_Page;

   -------------
   -- Refresh --
   -------------

   procedure Refresh (Item : Stores.Store) is
      Folder : constant String := Hostkit.Fs.Join (Stores.Root (Item), Directory);

      --  A page written where it differs, left where it cannot be.
      procedure Put (Name, Page : String) is
         Path   : constant String := Hostkit.Fs.Join (Folder, Name);
         Was    : Unbounded_String;
         Status : E.Error_Info;
      begin
         if Ada.Directories.Exists (Path) then
            Files.Read_Text (Path, Was, Status);
            if E.Is_Ok (Status) and then To_String (Was) = Page then
               return;
            end if;
         end if;
         Files.Write_Whole (Path, Page, Status);
      end Put;
   begin
      if not Stores.Is_Open (Item) or else Stores.Is_Read_Only (Item) then
         return;
      end if;
      if Lower (Scalar (Item, "views.markdown")) = "off" then
         Files.Discard (Hostkit.Fs.Join (Folder, "observations.md"));
         Files.Discard (Hostkit.Fs.Join (Folder, "derivations.md"));
         return;
      end if;
      if not Ada.Directories.Exists (Folder) then
         Ada.Directories.Create_Directory (Folder);
      end if;
      Put ("observations.md", Observations_Page (Item));
      Put ("derivations.md", Derivations_Page (Item));
   exception
      --  A page is a convenience: one the host will not let be made is
      --  not made, and the command that changed the project stands.
      when Ada.Directories.Name_Error | Ada.Directories.Use_Error =>
         null;
   end Refresh;

end Model_Runner.Framework.Views;
