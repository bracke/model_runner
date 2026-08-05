with Model_Runner.CLI.Options;
with Model_Runner.Localization;
with Model_Runner.Presentation;

--  Command execution.
--
--  Execution works from the typed Command value alone. It never looks at a raw
--  argument string, so every option conflict has already been settled by the
--  parser and there is nothing left here to reinterpret.
--
--  Each command returns the process exit status through the centralized
--  mapping in Model_Runner.Errors, so the same condition always produces the
--  same status.
--
--  Task safety: one command runs at a time on the calling task.
package Model_Runner.CLI.Execute is

   --  Run a parsed command.
   --
   --  @param Item Typed command.
   --  @param Screen Console for application output and diagnostics.
   --  @param Catalog Resolved message catalog.
   --  @param Status Process exit status.
   procedure Dispatch
     (Item    : Model_Runner.CLI.Options.Command;
      Screen  : in out Model_Runner.Presentation.Console;
      Catalog : Model_Runner.Localization.Catalog;
      Status  : out Natural);

end Model_Runner.CLI.Execute;
