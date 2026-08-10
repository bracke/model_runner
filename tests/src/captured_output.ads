--  Catch what the program writes on its real standard output.
--
--  Generated text is written through the raw stream of
--  Ada.Text_IO.Standard_Output, deliberately, so that Text_IO cannot touch
--  the bytes on their way out. Ada.Text_IO.Set_Output redirects
--  Current_Output, which that stream is not, so a test that runs a
--  generating command in this process cannot catch its text that way -- and
--  a test that tried caught a single newline and compared it with itself for
--  as long as it existed.
--
--  What leaked instead went to the terminal, into the middle of the suite's
--  own report. Seven fragments of generated text sat in it on every run.
--
--  This moves the descriptor rather than the Ada object: the file takes the
--  place of standard output for as long as it is open, so the raw stream
--  writes into it whatever it was told at elaboration. Diagnostics are not
--  affected -- those go through Current_Error, which Set_Error redirects and
--  which several tests already use.
--
--  Task safety: one at a time; it changes a process-wide descriptor.
package Captured_Output is

   --  Send standard output to a file until Close.
   --
   --  @param Path File to write; created, and overwritten if it exists.
   procedure Open (Path : String);

   --  Put standard output back and return what was caught.
   --
   --  @return Everything written while it was open.
   function Close return String;

   --  Whether the host let this work.
   --
   --  A host with no way to move a descriptor answers False from Open, and
   --  a test that needs the text should say so rather than compare two empty
   --  strings.
   --
   --  @return True when the last Open took effect.
   function Took_Effect return Boolean;

end Captured_Output;
