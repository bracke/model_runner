with Ada.Directories;
with Ada.Strings.Fixed;
with Model_Runner.Tools.Builtin;
with Model_Runner.Tools.Editing;
with Model_Runner.Tools.Schemas;

package body Model_Runner.Agent_Runtime is

   use Ada.Strings.Unbounded;

   -----------------
   -- Contract_Of --
   -----------------

   function Contract_Of (Arguments : String; Found : out Boolean) return Contract is
      Ignored : Boolean;
      function Get (Key : String) return Unbounded_String is
        (To_Unbounded_String (Model_Runner.Tools.Builtin.Text_Argument (Arguments, Key, Ignored)));
      Result : Contract;
   begin
      Result.Task_Text :=
        To_Unbounded_String (Model_Runner.Tools.Builtin.Text_Argument (Arguments, "task", Found));
      Found := Found and then Length (Result.Task_Text) > 0;
      Result.Role := Get ("role");
      Result.Need := Get ("need");
      Result.Acceptance := Get ("acceptance");
      for Key of Paths.Vector'(["inputs", "outputs"]) loop
         declare
            Items       : Model_Runner.Tools.Schemas.Choice_Lists.Vector;
            Given       : Boolean;
            Well_Formed : Boolean;
         begin
            Model_Runner.Tools.Builtin.Text_List_Argument (Arguments, Key, Items, Given, Well_Formed);
            if not Well_Formed and then Length (Result.Refusal) = 0 then
               Result.Refusal := To_Unbounded_String
                 (Key & " is a list of file paths, as [""src/a.adb"", ""docs/b.md""] -- not words");
            end if;
            for One of Items loop
               if Key = "inputs" then
                  Result.Inputs.Append (One);
               else
                  Result.Outputs.Append (One);
               end if;
            end loop;
         end;
      end loop;
      return Result;
   end Contract_Of;

   --  Paths, comma-separated.
   function Listed (Items : Paths.Vector) return String is
      Said : Unbounded_String;
   begin
      for One of Items loop
         Append (Said, (if Length (Said) = 0 then "" else ", ") & One);
      end loop;
      return To_String (Said);
   end Listed;

   -----------
   -- Brief --
   -----------

   function Brief (Item : Contract) return String is
     (To_String (Item.Task_Text)
      & (if Item.Inputs.Is_Empty then "" else ASCII.LF & "Start from: " & Listed (Item.Inputs))
      & (if Item.Outputs.Is_Empty then ""
         else ASCII.LF & "Write: " & Listed (Item.Outputs) & " -- the part is done when these are written")
      & (if Length (Item.Acceptance) = 0 then "" else ASCII.LF & "Done when: " & To_String (Item.Acceptance)));

   ------------
   -- Prints --
   ------------

   function Prints (Of_Files : Paths.Vector; Base : String := "") return Paths.Vector is
      Result : Paths.Vector;
   begin
      for Path of Of_Files loop
         declare
            Now : constant String := Model_Runner.Tools.Editing.Revision_Of (Path, Base);
         begin
            Result.Append (if Now = "" then "-" else Now);
         end;
      end loop;
      return Result;
   end Prints;

   ---------------
   -- Unwritten --
   ---------------

   function Unwritten (Of_Files : Paths.Vector; Before : Paths.Vector; Base : String := "") return String is
      Now    : constant Paths.Vector := Prints (Of_Files, Base);
      Result : Unbounded_String;
   begin
      for Index in Of_Files.First_Index .. Of_Files.Last_Index loop
         if Now (Index) = Before (Index) then
            Append (Result, (if Length (Result) = 0 then "" else ", ") & Of_Files (Index));
         end if;
      end loop;
      return To_String (Result);
   end Unwritten;

   ----------------------
   -- Named_But_Absent --
   ----------------------

   function Named_But_Absent (Task_Text : String; Base : String := "") return String is
      Result : Unbounded_String;
      Seen   : Paths.Vector;
      First  : Natural := Task_Text'First;

      function Is_Path (Word : String) return Boolean is
         Dot : constant Natural :=
           Ada.Strings.Fixed.Index (Word, ".", Ada.Strings.Backward);
      begin
         if Word'Length < 3 or else Word (Word'First) = '/'
           or else Ada.Strings.Fixed.Index (Word, "://") > 0
           or else (for some C of Word => C < ' ' or else C in '<' | '>' | '|' | '*' | '?')
         then
            return False;
         elsif Ada.Strings.Fixed.Index (Word, "/") > 0 then
            return True;
         end if;
         --  name.ext: a short extension of letters and digits after a name.
         return Dot > Word'First and then Dot < Word'Last
           and then Word'Last - Dot <= 5
           and then (for all C of Word (Dot + 1 .. Word'Last) =>
                       C in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9')
           and then (for some C of Word (Dot + 1 .. Word'Last) =>
                       C in 'a' .. 'z' | 'A' .. 'Z');
      end Is_Path;

      procedure Take (Raw : String) is
         From : Natural := Raw'First;
         To   : Natural := Raw'Last;
      begin
         while From <= To and then Raw (From) in '"' | ''' | '`' | '(' | '[' | '*' loop
            From := From + 1;
         end loop;
         while To >= From
           and then Raw (To) in '"' | ''' | '`' | ')' | ']' | '*' | ',' | '.' | ';' | ':' | '!' | '?'
         loop
            To := To - 1;
         end loop;
         if From <= To then
            declare
               Word : constant String := Raw (From .. To);
               Here : constant String := (if Base = "" then Word else Base & "/" & Word);
            begin
               if Is_Path (Word) and then not Seen.Contains (Word)
                 and then not Ada.Directories.Exists (Here)
               then
                  Seen.Append (Word);
                  Append (Result, (if Length (Result) = 0 then "" else ", ") & Word);
               end if;
            exception
               when others =>
                  null;
            end;
         end if;
      end Take;
   begin
      for Index in Task_Text'Range loop
         if Task_Text (Index) in ' ' | ASCII.HT | ASCII.LF | ASCII.CR then
            if Index > First then
               Take (Task_Text (First .. Index - 1));
            end if;
            First := Index + 1;
         end if;
      end loop;
      if First <= Task_Text'Last then
         Take (Task_Text (First .. Task_Text'Last));
      end if;
      return To_String (Result);
   end Named_But_Absent;

   ------------------
   -- Helper_Rules --
   ------------------

   function Helper_Rules return String
   is ("## What to do" & ASCII.LF
       & "Do what you are asked, with the tools you have, and nothing more."
       & " Paths are relative to the project. Only an edit_file or write_file call"
       & " changes a file, and only if you were asked to change one." & ASCII.LF & ASCII.LF
       & "When you are done, report in these lines:" & ASCII.LF & ASCII.LF
       & "status: done" & ASCII.LF
       & "summary: one line on what you found or did" & ASCII.LF
       & "findings: what you were asked for, in as many lines as it needs"
       & ASCII.LF & ASCII.LF
       & "If you could not do it, the status is failed and the summary says"
       & " why. Add changed_files: for any file you wrote." & ASCII.LF);

   --------------------
   -- Helper_Opening --
   --------------------

   function Helper_Opening (Role : String) return String
   is ("You are helping an agent with one part of its task"
       & (if Role = "" then "" else ", as its " & Role)
       & ". You cannot see its conversation, and it will see only your report.");

   ----------------------
   -- Run_Capabilities --
   ----------------------

   function Run_Capabilities
     (May_Delegate : Boolean; May_Ask : Boolean) return Tools.Registry.Capabilities
   is ([Tools.Registry.Delegation     => May_Delegate,
        Tools.Registry.Ask_User       => May_Ask,
        Tools.Registry.Project_Graph  => False,
        Tools.Registry.Project_Checks => False,
        Tools.Registry.Project_Knowledge => False,
        others                        => True]);

end Model_Runner.Agent_Runtime;
