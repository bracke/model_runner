with Ada.Streams.Stream_IO;
with Model_Runner.CLI.Execute.Support;
with Model_Runner.CLI.Execute.Help_Command;
with Model_Runner.CLI.Execute.Inspect_Command;
with Model_Runner.CLI.Execute.Embed_Command;
with Model_Runner.CLI.Execute.Run_Command;
with Model_Runner.CLI.Execute.Models_Command;

package body Model_Runner.CLI.Execute is

   use Model_Runner.CLI.Execute.Support;
   use Model_Runner.CLI.Execute.Help_Command;
   use Model_Runner.CLI.Execute.Inspect_Command;
   use Model_Runner.CLI.Execute.Embed_Command;
   use Model_Runner.CLI.Execute.Run_Command;
   use Model_Runner.CLI.Execute.Models_Command;
   use type Opt.Command_Kind;

   --  Write bytes to a path, replacing whatever was there.
   --
   --  Here rather than in the engine: the units that interpret what a model
   --  says may not reach the filesystem, and a saved context is written by
   --  the program rather than by the model.
   procedure Write_File
     (Path   : String;
      Data   : Model_Runner.Bytes.Byte_Array;
      Status : out E.Error_Info)
   is
      use Ada.Streams;

      --  A saved context runs to many megabytes, so the bytes are written
      --  a chunk at a time from a fixed buffer rather than copied whole
      --  onto the stack, which a large snapshot would overflow.
      Chunk : constant := 64 * 1024;

      Handle : Ada.Streams.Stream_IO.File_Type;
      Block  : Stream_Element_Array (1 .. Chunk);
      At_Byte : Stream_Element_Offset := 0;
   begin
      Status := E.Success;

      begin
         Ada.Streams.Stream_IO.Create
           (Handle, Ada.Streams.Stream_IO.Out_File, Path);
         for Value of Data loop
            At_Byte := At_Byte + 1;
            Block (At_Byte) := Stream_Element (Value);
            if At_Byte = Block'Last then
               Ada.Streams.Stream_IO.Write (Handle, Block);
               At_Byte := 0;
            end if;
         end loop;
         if At_Byte > 0 then
            Ada.Streams.Stream_IO.Write (Handle, Block (1 .. At_Byte));
         end if;
         Ada.Streams.Stream_IO.Close (Handle);
      exception
         when others =>
            if Ada.Streams.Stream_IO.Is_Open (Handle) then
               Ada.Streams.Stream_IO.Close (Handle);
            end if;
            Status := E.Make (E.IO_Open_Failed);
            E.Add_Text (Status, "path", Path, E.Param_Path);
      end;
   end Write_File;

   procedure Dispatch
     (Item    : Opt.Command;
      Screen  : in out Pres.Console;
      Catalog : Loc.Catalog;
      Status  : out Natural) is
   begin
      case Item.Kind is
         when Opt.Command_Version =>
            Show_Version (Screen);
            Status := E.Exit_Success;

         when Opt.Command_Help =>
            Show_Help (Screen, T.To_String (Item.Help_Topic));
            Status := E.Exit_Success;

         when Opt.Command_Inspect =>
            Do_Inspect (Item, Screen, Status);

         when Opt.Command_Models =>
            Do_Models (Item, Screen, Status);

         when Opt.Command_Run =>
            if T.Is_Empty (Item.Model_Path) then
               declare
                  Chosen : Opt.Command := Item;
                  Picked : Boolean;
               begin
                  Choose_Model (Screen, Chosen.Model_Path, Picked);
                  if Picked then
                     Do_Run (With_Panels (Resolved_Backend (Chosen, Screen)), Screen,
                             Catalog, Status);
                  else
                     Pres.Report (Screen, E.Make (E.CLI_Missing_Model_Path));
                     Status := E.Exit_Usage;
                  end if;
               end;
            else
               Do_Run (With_Panels (Resolved_Backend (Item, Screen)), Screen, Catalog,
                       Status);
            end if;

         when Opt.Command_Embed =>
            Do_Embed (Item, Screen, Status);

         when Opt.Command_None =>
            Pres.Report (Screen, E.Make (E.CLI_Missing_Command));
            Status := E.Exit_Usage;
      end case;
   exception
      when Failure : others =>
         Pres.Report (Screen, E.Unexpected (Failure, "command " & Opt.Command_Kind'Image (Item.Kind)));
         Status := E.Exit_Internal;
   end Dispatch;

end Model_Runner.CLI.Execute;
