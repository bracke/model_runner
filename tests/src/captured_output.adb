with Ada.Text_IO;

with Hostkit.Descriptors;

with Project_Tools.Files;

package body Captured_Output is

   package D renames Hostkit.Descriptors;

   use type D.Descriptor;

   --  Where standard output goes while a capture is open, and where it came
   --  from. Both are host descriptors rather than Ada objects, because what
   --  has to move is the descriptor: Ada.Text_IO.Set_Output moves
   --  Current_Output, and the stream generated text is written through is
   --  Standard_Output, which is not the same thing.
   --
   --  The first version bound open, dup, dup2 and close by their POSIX
   --  names. That worked here and would not have linked on Windows, where
   --  they are spelled with a leading underscore -- in the crate whose own
   --  checks demand that every host body compile for every host. Hostkit
   --  already knew the answer: Assign is dup2 on POSIX and SetStdHandle on
   --  Windows, and says so in its own comment.
   Saved   : D.Descriptor := D.Invalid;
   Opened  : D.Descriptor := D.Invalid;
   Working : Boolean := False;
   Worked  : Boolean := False;
   Where   : String (1 .. 512);
   Where_L : Natural := 0;

   ----------
   -- Open --
   ----------

   procedure Open (Path : String) is
   begin
      --  One at a time. This holds a single saved descriptor, so a second
      --  Open inside the first would overwrite it and the first Close would
      --  restore standard output to the other capture rather than to where
      --  it started. That is not hypothetical: nesting a capture inside a
      --  capture is how the whole suite's report went missing, two of
      --  fifty-seven opens never being closed.
      if Working then
         raise Program_Error with "a capture is already open";
      end if;

      Working := False;
      Worked := False;
      Where_L := Natural'Min (Path'Length, Where'Length);
      Where (1 .. Where_L) := Path (Path'First .. Path'First + Where_L - 1);

      if not D.Open_File (Path, D.Open_Write_Truncate, Opened) then
         return;
      end if;

      --  Flush first: anything Text_IO is holding belongs to the caller's
      --  output and not to the file about to take its place.
      Ada.Text_IO.Flush (Ada.Text_IO.Standard_Output);

      Saved := D.Duplicate (D.Standard_Output);
      if Saved = D.Invalid then
         D.Close (Opened);
         return;
      end if;

      if not D.Assign (Opened, D.Stream_Output) then
         D.Close (Saved);
         D.Close (Opened);
         return;
      end if;

      Working := True;
      Worked := True;
   end Open;

   -----------
   -- Close --
   -----------

   function Close return String is
      Put_Back : Boolean;
   begin
      if not Working then
         return "";
      end if;

      Ada.Text_IO.Flush (Ada.Text_IO.Standard_Output);

      Put_Back := D.Assign (Saved, D.Stream_Output);
      pragma Unreferenced (Put_Back);

      D.Close (Saved);
      D.Close (Opened);
      Working := False;

      return Project_Tools.Files.Read_Raw_File (Where (1 .. Where_L));
   end Close;

   -----------------
   -- Took_Effect --
   -----------------

   function Took_Effect return Boolean is (Worked);

end Captured_Output;
