with Ada.Strings.Unbounded;

with Model_Runner.Errors;
with Model_Runner.Framework.Stores;

--  Every external program the harness runs, run one way.
--
--  A command runs only when the project's policy allows its program --
--  the configuration's set execution.allowed names them -- and only
--  directly: a command that needs a shell (&&, a pipe, a redirection) is
--  refused unless the policy says scalar execution.shell = allowed. It runs
--  in a directory inside the project, with nothing on its standard input,
--  with PATH, HOME and the variables set execution.environment names and
--  no others, under a deadline, and with its output kept -- whole as a raw
--  log among the results, and cut to a limit where it is read. Having the
--  right to run a build is not having a shell: an agent is given the
--  checks the configuration defines, not this.
package Model_Runner.Framework.Execution is

   --  What may be run, and how.
   type Policy is record
      --  The programs that may run, by name.
      Allowed       : Name_Lists.Vector;
      Shell_Allowed : Boolean := False;

      --  Variables passed beyond PATH and HOME, separated by commas.
      Environment   : Ada.Strings.Unbounded.Unbounded_String;

      Timeout       : Positive := 600;
      Output_Limit  : Positive := 1024 * 1024;

      --  Whether a check may use the network. Recorded with what ran; the
      --  host does not enforce it.
      Network       : Boolean := False;
   end record;

   --  What became of a command.
   type Outcome is record
      Command     : Ada.Strings.Unbounded.Unbounded_String;
      Directory   : Ada.Strings.Unbounded.Unbounded_String;
      Started     : Boolean := False;
      Timed_Out   : Boolean := False;
      Exit_Status : Integer := -1;
      Seconds     : Natural := 0;

      --  Standard output and standard error together, cut to the limit.
      Output      : Ada.Strings.Unbounded.Unbounded_String;

      --  The result the whole output is kept as.
      Raw_Log     : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  The project's policy, from its configuration.
   --
   --  @param Item The store.
   --  @return The policy.
   function Policy_Of (Item : Stores.Store) return Policy;

   --  Whether a command needs a shell to run as written.
   --
   --  @param Command The command.
   --  @return True when it holds a shell's operators.
   function Needs_Shell (Command : String) return Boolean;

   --  A command's words, as a shell would split plain ones: at blanks,
   --  with quoted stretches kept whole.
   --
   --  @param Command The command.
   --  @return Its words.
   function Words_Of (Command : String) return Name_Lists.Vector;

   --  Run a command.
   --
   --  @param Item The store, whose project the command runs in.
   --  @param Change The transaction the raw log is staged in.
   --  @param Rules The policy.
   --  @param Command What to run.
   --  @param Directory Where, inside the project; empty for its top.
   --  @param Result What became of it.
   --  @param Status Framework_Execution_Refused when the policy does not
   --    allow it; a success whatever the command itself returned.
   procedure Run
     (Item      : Stores.Store;
      Change    : in out Stores.Transaction;
      Rules     : Policy;
      Command   : String;
      Directory : String;
      Result    : out Outcome;
      Status    : out Model_Runner.Errors.Error_Info);

end Model_Runner.Framework.Execution;
