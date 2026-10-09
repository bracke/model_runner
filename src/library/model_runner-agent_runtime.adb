with Ada.Strings.Fixed;
with Model_Runner.Tools.Builtin;
with Model_Runner.Tools.Editing;

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
      Result.Inputs := Get ("inputs");
      Result.Outputs := Get ("outputs");
      Result.Acceptance := Get ("acceptance");
      return Result;
   end Contract_Of;

   -----------
   -- Brief --
   -----------

   function Brief (Item : Contract) return String is
     (To_String (Item.Task_Text)
      & (if Length (Item.Inputs) = 0 then "" else ASCII.LF & "Start from: " & To_String (Item.Inputs))
      & (if Length (Item.Outputs) = 0 then ""
         else ASCII.LF & "Write: " & To_String (Item.Outputs) & " -- the part is done when these are written")
      & (if Length (Item.Acceptance) = 0 then "" else ASCII.LF & "Done when: " & To_String (Item.Acceptance)));

   ------------------
   -- Output_Paths --
   ------------------

   function Output_Paths (Item : Contract) return Paths.Vector is
      Outputs : constant String := To_String (Item.Outputs);
      Result  : Paths.Vector;
      Start   : Natural := Outputs'First;
      --  A word that names a file: a folder or an extension in it, and
      --  nothing a sentence has. Outputs described in words -- "the result
      --  of 6 * 7" -- name no file, and none is held to be written.
      function Path_Like (Word : String) return Boolean is
        ((Ada.Strings.Fixed.Index (Word, "/") > 0
          or else (Ada.Strings.Fixed.Index (Word, ".") > Word'First
                   and then Ada.Strings.Fixed.Index (Word, ".") < Word'Last))
         and then (for all C of Word => C not in '*' | '?' | '"' | '(' | ')'));
   begin
      for Index in Outputs'First .. Outputs'Last + 1 loop
         if Index > Outputs'Last or else Outputs (Index) in ',' | ' ' | ASCII.LF then
            if Index > Start and then Path_Like (Outputs (Start .. Index - 1)) then
               Result.Append (Outputs (Start .. Index - 1));
            end if;
            Start := Index + 1;
         end if;
      end loop;
      return Result;
   end Output_Paths;

   ------------
   -- Prints --
   ------------

   function Prints (Of_Files : Paths.Vector) return Paths.Vector is
      Result : Paths.Vector;
   begin
      for Path of Of_Files loop
         declare
            Now : constant String := Model_Runner.Tools.Editing.Revision_Of (Path);
         begin
            Result.Append (if Now = "" then "-" else Now);
         end;
      end loop;
      return Result;
   end Prints;

   ---------------
   -- Unwritten --
   ---------------

   function Unwritten (Of_Files : Paths.Vector; Before : Paths.Vector) return String is
      Now    : constant Paths.Vector := Prints (Of_Files);
      Result : Unbounded_String;
   begin
      for Index in Of_Files.First_Index .. Of_Files.Last_Index loop
         if Now (Index) = Before (Index) then
            Append (Result, (if Length (Result) = 0 then "" else ", ") & Of_Files (Index));
         end if;
      end loop;
      return To_String (Result);
   end Unwritten;

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
        others                        => True]);

end Model_Runner.Agent_Runtime;
