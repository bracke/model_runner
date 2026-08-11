with Ada.Directories;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;

with Project_Tools.Processes;

package body Pristine is

   --  Where the clone goes: beside the repository, so that every path pin --
   --  ../hostkit, ../messages and the rest -- resolves to the sibling that is
   --  already there. Nothing is copied and nothing is linked.
   Clone_Name : constant String := "model_runner-pristine";

   --  Run one command in a directory and say whether it succeeded.
   function Ran_Well
     (Label   : String;
      Dir     : String;
      Program : String;
      Args    : Project_Tools.Processes.Argument_Vectors.Vector)
      return Boolean
   is
      Found : constant String :=
        Project_Tools.Processes.Locate_Command (Program);
   begin
      if Found = "" then
         return False;
      end if;

      return Project_Tools.Processes.Run_Status
               (Label   => Label,
                Dir     => Dir,
                Program => Found,
                Args    => Args,
                Quiet   => True) = 0;
   end Ran_Well;

   --  A vector of arguments, written as one call.
   function Words (A, B, C, D : String := "")
     return Project_Tools.Processes.Argument_Vectors.Vector
   is
      Held : Project_Tools.Processes.Argument_Vectors.Vector;
   begin
      if A /= "" then
         Held.Append (To_Unbounded_String (A));
      end if;
      if B /= "" then
         Held.Append (To_Unbounded_String (B));
      end if;
      if C /= "" then
         Held.Append (To_Unbounded_String (C));
      end if;
      if D /= "" then
         Held.Append (To_Unbounded_String (D));
      end if;
      return Held;
   end Words;

   --  A built executable, by whichever name this host gives it.
   --
   --  Naming the Unix one alone is how the repacking comparison came to
   --  report that the command was not built, on the host that writes .exe.
   --  Nothing here had run there yet, which is the only reason these two
   --  had not done the same.
   function Built (Path : String) return String is
   begin
      if Ada.Directories.Exists (Path & ".exe") then
         return Path & ".exe";
      else
         return Path;
      end if;
   end Built;

   ---------
   -- Run --
   ---------

   procedure Run (Root : String; Result : out Report) is
      procedure Say (Text : String) is
         Room : constant Natural :=
           Natural'Min (Text'Length, Result.Detail'Length);
      begin
         Result.Detail (1 .. Room) :=
           Text (Text'First .. Text'First + Room - 1);
         Result.Used := Room;
      end Say;

      Full   : constant String := Ada.Directories.Full_Name (Root);
      Beside : constant String := Ada.Directories.Containing_Directory (Full);
      Target : constant String := Beside & "/" & Clone_Name;

      procedure Note_Where is
         Room : constant Natural :=
           Natural'Min (Target'Length, Result.Where'Length);
      begin
         Result.Where (1 .. Room) :=
           Target (Target'First .. Target'First + Room - 1);
         Result.Where_L := Room;
      end Note_Where;

      package IO renames Ada.Text_IO;
   begin
      Result := (others => <>);
      Note_Where;

      --  Refused rather than removed. Deleting a directory somebody else
      --  made, because its name matched, is not this command's business.
      if Ada.Directories.Exists (Target) then
         Say ("a clone is already at that path; remove it and run again");
         return;
      end if;

      IO.Put_Line (IO.Standard_Error, "==> clone what git carries");
      if not Ran_Well ("clone", Beside, "git",
                       Words ("clone", "-q", Full, Clone_Name))
      then
         Say ("git could not clone the repository");
         return;
      end if;

      IO.Put_Line (IO.Standard_Error, "==> resolve the pins and build");
      if not Ran_Well ("update", Target, "alr",
                       Words ("--non-interactive", "update"))
        or else not Ran_Well ("build", Target, "alr",
                              Words ("--non-interactive", "build"))
      then
         Say ("the clone does not build; what is here and not committed is "
              & "the difference");
         return;
      end if;

      IO.Put_Line (IO.Standard_Error, "==> build the tests crate");
      if not Ran_Well ("update tests", Target & "/tests", "alr",
                       Words ("--non-interactive", "update"))
        or else not Ran_Well ("build tests", Target & "/tests", "alr",
                              Words ("--non-interactive", "build"))
      then
         Say ("the tests crate does not build in the clone");
         return;
      end if;

      IO.Put_Line (IO.Standard_Error, "==> run the suite in the clone");
      if not Ran_Well ("suite", Target & "/tests",
                       Built (Target & "/tests/bin/tests"),
                       Words ("test"))
      then
         Say ("the suite fails on a tree holding only what git carries");
         return;
      end if;

      IO.Put_Line (IO.Standard_Error, "==> run the repository checks there");
      if not Ran_Well ("checks", Target & "/tests",
                       Built (Target & "/tests/bin/tests"),
                       Words ("check", ".."))
      then
         Say ("the repository checks fail in the clone");
         return;
      end if;

      Result.Ran := True;
      Say ("the clone builds, the suite passes and the checks pass");

      --  Removed on success, kept on failure. A clone that proved the point
      --  is rubbish; a clone that failed is the evidence, and it is where
      --  the summary says it is.
      begin
         Ada.Directories.Delete_Tree (Target);
         Result.Where_L := 0;
      exception
         when others =>
            null;
      end;
   end Run;

   -------------
   -- Summary --
   -------------

   function Summary (Item : Report) return String is
   begin
      return Item.Detail (1 .. Item.Used)
        & (if Item.Where_L = 0 then ""
           else "; the clone is at " & Item.Where (1 .. Item.Where_L));
   end Summary;

end Pristine;
