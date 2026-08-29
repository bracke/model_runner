with Ada.Calendar;
with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Text_IO;

package body Shader_Generation is

   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   --  A number in hexadecimal, without the base Ada would write.
   function Hex (Value : Interfaces.Unsigned_64) return String is
      Digits_Of : constant String := "0123456789ABCDEF";
      Room      : String (1 .. 16) := [others => '0'];
      Left      : Interfaces.Unsigned_64 := Value;
   begin
      for Index in reverse Room'Range loop
         Room (Index) := Digits_Of (Natural (Left and 16#F#) + 1);
         Left := Interfaces.Shift_Right (Left, 4);
      end loop;
      return Room;
   end Hex;

   function Hex (Value : Interfaces.Unsigned_32) return String is
      Digits_Of : constant String := "0123456789ABCDEF";
      Room      : String (1 .. 8) := [others => '0'];
      Left      : Interfaces.Unsigned_32 := Value;
   begin
      for Index in reverse Room'Range loop
         Room (Index) := Digits_Of (Natural (Left and 16#F#) + 1);
         Left := Interfaces.Shift_Right (Left, 4);
      end loop;
      return Room;
   end Hex;

   --  Read a whole file as bytes, or report that it could not be.
   procedure Read_All
     (Path  : String;
      Room  : out Ada.Streams.Stream_Element_Array;
      Last  : out Ada.Streams.Stream_Element_Offset;
      Found : out Boolean)
   is
      use Ada.Streams;
      Handle : Stream_IO.File_Type;
   begin
      Last := 0;
      Found := False;

      if not Ada.Directories.Exists (Path) then
         return;
      end if;

      Stream_IO.Open (Handle, Stream_IO.In_File, Path);
      Stream_IO.Read (Handle, Room, Last);
      Stream_IO.Close (Handle);
      Found := True;
   exception
      when others =>
         Found := False;
   end Read_All;

   --------------------
   -- Source_Digest --
   --------------------

   function Source_Digest
     (Path : String; Found : out Boolean) return Interfaces.Unsigned_64
   is
      use Ada.Streams;

      Room   : Stream_Element_Array (1 .. 1_000_000);
      Last   : Stream_Element_Offset;
      Digest : Interfaces.Unsigned_64 := 16#CBF2_9CE4_8422_2325#;
   begin
      Read_All (Path, Room, Last, Found);
      if not Found then
         return 0;
      end if;

      --  Every byte but the ones a line ending differs by, so that a file
      --  checked out on another host has the same digest as here.
      for Index in 1 .. Last loop
         if Room (Index) /= 13 then
            Digest :=
              (Digest xor Interfaces.Unsigned_64 (Room (Index)))
              * 16#0000_0100_0000_01B3#;
         end if;
      end loop;

      return Digest;
   end Source_Digest;

   -------------------
   -- Write_Shader --
   -------------------

   --  The Ada name a shader source carries: its file name without the
   --  directory or the extension, in title case with underscores kept.
   --  row_product.comp becomes Row_Product.
   function Ada_Name (Path : String) return String is
      First : Natural := Path'First;
      Last  : Natural := Path'Last;
   begin
      for Index in reverse Path'Range loop
         if Path (Index) = '/' then
            First := Index + 1;
            exit;
         end if;
      end loop;

      for Index in reverse First .. Path'Last loop
         if Path (Index) = '.' then
            Last := Index - 1;
            exit;
         end if;
      end loop;

      declare
         Kept  : String := Path (First .. Last);
         Start : Boolean := True;
      begin
         for Index in Kept'Range loop
            if Start and then Kept (Index) in 'a' .. 'z' then
               Kept (Index) :=
                 Character'Val (Character'Pos (Kept (Index)) - 32);
            end if;
            Start := Kept (Index) = '_';
         end loop;
         return Kept;
      end;
   end Ada_Name;

   procedure Write_Shaders
     (Root    : String;
      Shaders : Shader_Pairs;
      Written : out Boolean)
   is
      use Ada.Streams;

      Target : constant String :=
        Root & "/src/library/model_runner-shaders.ads";

      Handle : Ada.Text_IO.File_Type;

      --  Write one shader's digest and words.
      procedure Emit (Pair : Shader_Pair; Ok : out Boolean);

      procedure Emit (Pair : Shader_Pair; Ok : out Boolean) is
         Room : Stream_Element_Array (1 .. 1_000_000);
         Last : Stream_Element_Offset;
         Read : Boolean;

         Digest : Interfaces.Unsigned_64;
         Marked : Boolean;

         --  Named for the compiled file rather than the source, so that
         --  one shader may be compiled twice and reach the engine as two
         --  constants. The matrix product is: a pipeline pays for every
         --  branch compiled into it whether or not the branch is taken --
         --  twenty-one per cent, measured -- so the formats it decodes are
         --  split across two compilations of one source. The digest below
         --  is still the source's, which is what the staleness check wants
         --  and is the same for both.
         --
         --  Every shader that is compiled once is unaffected: its two names
         --  agree.
         Name : constant String := Ada_Name (Pair.Compiled.all);
      begin
         Ok := False;

         Read_All (Pair.Compiled.all, Room, Last, Read);
         if not Read or else Last = 0 or else Last mod 4 /= 0 then
            return;
         end if;

         Digest := Source_Digest (Pair.Source.all, Marked);
         if not Marked then
            return;
         end if;

         --  A compiled file older than the source it claims to be compiled
         --  from is a compiled file somebody forgot to make again.
         --
         --  This tool took the words on trust, and the check beside it
         --  compares the source against a digest recorded here -- so
         --  handing it a stale .spv updated the digest and left the words,
         --  and neither of them could tell. It happened: matrix_product.comp
         --  said a tile of a hundred and twenty-eight and the words
         --  committed beside it were built from sixty-four, and every device
         --  figure this repository published described the sixty-four. The
         --  edit had never once run.
         --
         --  A modification time is a weak thing to lean on and it is the
         --  only thing here that knows. It catches the case that happened:
         --  the source is edited, the compiler is not run, and the tool is.
         if Ada.Calendar."<"
              (Ada.Directories.Modification_Time (Pair.Compiled.all),
               Ada.Directories.Modification_Time (Pair.Source.all))
         then
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "shader: " & Pair.Compiled.all & " is older than "
               & Pair.Source.all
               & "; compile it again before naming it here");
            return;
         end if;

         Ada.Text_IO.Put_Line
           (Handle, "   --  Digest of " & Pair.Source.all & " when these");
         Ada.Text_IO.Put_Line (Handle, "   --  words were made from it.");
         Ada.Text_IO.Put_Line
           (Handle,
            "   " & Name & "_Digest : constant Interfaces.Unsigned_64 :=");
         Ada.Text_IO.Put_Line
           (Handle, "     16#" & Hex (Digest) & "#;");
         Ada.Text_IO.New_Line (Handle);
         Ada.Text_IO.Put_Line
           (Handle, "   --  The compiled words, as the device is given them.");
         Ada.Text_IO.Put_Line
           (Handle, "   " & Name & " : constant Word_Array :=");

         declare
            Words : constant Stream_Element_Offset := Last / 4;
            Column : Natural := 0;
         begin
            Ada.Text_IO.Put (Handle, "     [");

            for Index in 1 .. Words loop
               declare
                  At_Byte : constant Stream_Element_Offset :=
                    (Index - 1) * 4 + 1;

                  Value : constant Interfaces.Unsigned_32 :=
                    Interfaces.Unsigned_32 (Room (At_Byte))
                    or Interfaces.Shift_Left
                         (Interfaces.Unsigned_32 (Room (At_Byte + 1)), 8)
                    or Interfaces.Shift_Left
                         (Interfaces.Unsigned_32 (Room (At_Byte + 2)), 16)
                    or Interfaces.Shift_Left
                         (Interfaces.Unsigned_32 (Room (At_Byte + 3)), 24);

                  Text : constant String := "16#" & Hex (Value) & "#";
               begin
                  if Column = 0 and then Index > 1 then
                     Ada.Text_IO.Put_Line (Handle, "");
                     Ada.Text_IO.Put (Handle, "      ");
                  end if;

                  Ada.Text_IO.Put (Handle, Text);

                  --  The separator goes before the next word rather than
                  --  after this one when the line ends here, because a comma
                  --  and a space at the end of a line is a trailing space,
                  --  and the gate refuses a build that leaves style warnings
                  --  behind.
                  Column := Column + 1;
                  if Column = 5 then
                     Column := 0;
                  end if;

                  if Index < Words and then Column /= 0 then
                     Ada.Text_IO.Put (Handle, ", ");
                  elsif Index < Words then
                     Ada.Text_IO.Put (Handle, ",");
                  end if;
               end;
            end loop;

            Ada.Text_IO.Put_Line (Handle, "];");
         end;

         Ok := True;
      end Emit;

      Good : Boolean;
   begin
      Written := False;

      if Shaders'Length = 0 then
         return;
      end if;

      Ada.Text_IO.Create (Handle, Ada.Text_IO.Out_File, Target);

      Ada.Text_IO.Put_Line (Handle, "with Interfaces;");
      Ada.Text_IO.New_Line (Handle);
      Ada.Text_IO.Put_Line (Handle, "--  Compiled shaders, as the words a device is given.");
      Ada.Text_IO.Put_Line (Handle, "--");
      Ada.Text_IO.Put_Line (Handle, "--  Generated by `tests shader` from the sources under");
      Ada.Text_IO.Put_Line (Handle, "--  src/shaders. Do not edit: edit the shader, compile it, and");
      Ada.Text_IO.Put_Line (Handle, "--  run the tool again with every shader named.");
      Ada.Text_IO.Put_Line (Handle, "--");
      Ada.Text_IO.Put_Line (Handle, "--  The digest below each name is of the shader source those");
      Ada.Text_IO.Put_Line (Handle, "--  words were compiled from. The release checklist compares it");
      Ada.Text_IO.Put_Line (Handle, "--  against the source in the tree, so a shader that has been");
      Ada.Text_IO.Put_Line (Handle, "--  edited and not recompiled is caught rather than quietly");
      Ada.Text_IO.Put_Line (Handle, "--  stale.");
      Ada.Text_IO.Put_Line (Handle, "--");
      Ada.Text_IO.Put_Line (Handle, "--  Task safety: constants, readable from any task.");
      Ada.Text_IO.Put_Line (Handle, "package Model_Runner.Shaders is");
      Ada.Text_IO.New_Line (Handle);
      Ada.Text_IO.Put_Line (Handle, "   type Word_Array is array (Positive range <>) of");
      Ada.Text_IO.Put_Line (Handle, "     Interfaces.Unsigned_32;");
      Ada.Text_IO.New_Line (Handle);

      for Index in Shaders'Range loop
         Emit (Shaders (Index), Good);
         if not Good then
            Ada.Text_IO.Close (Handle);
            return;
         end if;

         if Index < Shaders'Last then
            Ada.Text_IO.New_Line (Handle);
         end if;
      end loop;

      Ada.Text_IO.New_Line (Handle);
      Ada.Text_IO.Put_Line (Handle, "end Model_Runner.Shaders;");
      Ada.Text_IO.Close (Handle);

      Written := True;
   exception
      when others =>
         if Ada.Text_IO.Is_Open (Handle) then
            Ada.Text_IO.Close (Handle);
         end if;
         Written := False;
   end Write_Shaders;

end Shader_Generation;
