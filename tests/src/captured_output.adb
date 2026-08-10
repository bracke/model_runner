with Ada.Text_IO;
with Interfaces.C;
with Interfaces.C.Strings;

with Project_Tools.Files;

package body Captured_Output is

   use type Interfaces.C.int;

   --  The three host calls this needs, bound directly. Binding to a host
   --  call is not writing in another language, which is how the library
   --  itself reaches mmap and isatty.
   function C_Open
     (Path : Interfaces.C.Strings.chars_ptr;
      Flags : Interfaces.C.int;
      Mode  : Interfaces.C.int) return Interfaces.C.int
     with Import, Convention => C, External_Name => "open";

   function C_Close (Descriptor : Interfaces.C.int) return Interfaces.C.int
     with Import, Convention => C, External_Name => "close";

   function C_Dup (Descriptor : Interfaces.C.int) return Interfaces.C.int
     with Import, Convention => C, External_Name => "dup";

   function C_Dup2 (From, To : Interfaces.C.int) return Interfaces.C.int
     with Import, Convention => C, External_Name => "dup2";

   --  O_WRONLY or O_CREAT or O_TRUNC, and mode 0644, as Linux and macOS
   --  spell them. A host that spells them otherwise fails to open and says
   --  so through Took_Effect rather than writing somewhere unexpected.
   Write_Create_Truncate : constant Interfaces.C.int := 8#1101#;
   Owner_Read_Write      : constant Interfaces.C.int := 8#644#;

   Standard_Output : constant Interfaces.C.int := 1;

   Saved   : Interfaces.C.int := -1;
   Opened  : Interfaces.C.int := -1;
   Working : Boolean := False;
   Worked  : Boolean := False;
   Where   : String (1 .. 512);
   Where_L : Natural := 0;

   ----------
   -- Open --
   ----------

   procedure Open (Path : String) is
      Name : Interfaces.C.Strings.chars_ptr :=
        Interfaces.C.Strings.New_String (Path);
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

      Opened := C_Open (Name, Write_Create_Truncate, Owner_Read_Write);
      Interfaces.C.Strings.Free (Name);

      if Opened < 0 then
         return;
      end if;

      --  Flush first: anything Text_IO is holding belongs to the caller's
      --  output and not to the file about to take its place.
      Ada.Text_IO.Flush (Ada.Text_IO.Standard_Output);

      Saved := C_Dup (Standard_Output);
      if Saved < 0 then
         if C_Close (Opened) < 0 then
            null;
         end if;
         Opened := -1;
         return;
      end if;

      if C_Dup2 (Opened, Standard_Output) < 0 then
         if C_Close (Saved) < 0 then
            null;
         end if;
         if C_Close (Opened) < 0 then
            null;
         end if;
         Saved := -1;
         Opened := -1;
         return;
      end if;

      Working := True;
      Worked := True;
   end Open;

   -----------
   -- Close --
   -----------

   function Close return String is
   begin
      if not Working then
         return "";
      end if;

      Ada.Text_IO.Flush (Ada.Text_IO.Standard_Output);

      if C_Dup2 (Saved, Standard_Output) < 0 then
         null;
      end if;

      if C_Close (Saved) < 0 then
         null;
      end if;

      if C_Close (Opened) < 0 then
         null;
      end if;

      Saved := -1;
      Opened := -1;
      Working := False;

      return Project_Tools.Files.Read_Raw_File (Where (1 .. Where_L));
   end Close;

   ------------------
   -- Took_Effect --
   ------------------

   function Took_Effect return Boolean is (Worked);

end Captured_Output;
