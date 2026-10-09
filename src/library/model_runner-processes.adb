with Ada.Directories;
with Ada.Finalization;
with Ada.Streams.Stream_IO;

with GNAT.OS_Lib;

package body Model_Runner.Processes is

   package U renames Ada.Strings.Unbounded;

   --  A temporary file, gone when the holder is: whatever raises between
   --  making it and reading it, nothing is left behind.
   type Temporary is new Ada.Finalization.Limited_Controlled with record
      Path : GNAT.OS_Lib.String_Access;
   end record;

   overriding procedure Initialize (Item : in out Temporary);
   overriding procedure Finalize (Item : in out Temporary);

   overriding procedure Initialize (Item : in out Temporary) is
      Handle : GNAT.OS_Lib.File_Descriptor;
   begin
      GNAT.OS_Lib.Create_Temp_File (Handle, Item.Path);
      GNAT.OS_Lib.Close (Handle);
   end Initialize;

   overriding procedure Finalize (Item : in out Temporary) is
      use type GNAT.OS_Lib.String_Access;
      Gone : Boolean;
   begin
      if Item.Path /= null then
         GNAT.OS_Lib.Delete_File (Item.Path.all, Gone);
         GNAT.OS_Lib.Free (Item.Path);
      end if;
   end Finalize;

   function Image (Value : Integer) return String is
      Raw : constant String := Integer'Image (Value);
   begin
      return (if Value < 0 then Raw else Raw (Raw'First + 1 .. Raw'Last));
   end Image;

   --  A captured stream, as much as is kept of it.
   procedure Read_Bounded (Path : String; Text : out U.Unbounded_String; Cut : out Boolean) is
      use Ada.Streams;
      File : Stream_IO.File_Type;

      function Bytes (From, Count : Natural) return String is
         Block : Stream_Element_Array (1 .. Stream_Element_Offset (Count));
         Last  : Stream_Element_Offset := 0;
         Said  : String (1 .. Count);
      begin
         if Count = 0 then
            return "";
         end if;
         Stream_IO.Set_Index (File, Stream_IO.Positive_Count (From));
         Stream_IO.Read (File, Block, Last);
         for Index in 1 .. Natural (Last) loop
            Said (Index) := Character'Val (Block (Stream_Element_Offset (Index)));
         end loop;
         return Said (1 .. Natural (Last));
      end Bytes;
   begin
      Text := U.Null_Unbounded_String;
      Cut := False;
      if not Ada.Directories.Exists (Path) then
         return;
      end if;
      Stream_IO.Open (File, Stream_IO.In_File, Path);
      declare
         Size : constant Natural := Natural (Stream_IO.Size (File));
         Head : constant Natural := Stream_Most * 3 / 5;
         Tail : constant Natural := Stream_Most - Head;
      begin
         if Size <= Stream_Most then
            Text := U.To_Unbounded_String (Bytes (1, Size));
         else
            Cut := True;
            Text := U.To_Unbounded_String
              (Bytes (1, Head) & ASCII.LF & "...[" & Image (Size - Head - Tail) & " bytes left out]..."
               & ASCII.LF & Bytes (Size - Tail + 1, Tail));
         end if;
      end;
      Stream_IO.Close (File);
   exception
      when others =>
         if Stream_IO.Is_Open (File) then
            Stream_IO.Close (File);
         end if;
   end Read_Bounded;

   ---------
   -- Run --
   ---------

   function Run (Item : Request) return Result is
      Output  : Temporary;
      Errors  : Temporary;
      Result_Of : Result;
      Where   : constant String :=
        Hostkit.Process.Locate (U.To_String (Item.Program));
   begin
      if Where = "" then
         return Result_Of;
      end if;
      declare
         Happened : constant Hostkit.Process.Process_Outcome :=
           Hostkit.Process.Run_Captured
             (Program           => Where,
              Arguments         => Item.Arguments,
              Working_Directory => U.To_String (Item.Directory),
              Stdout_Path       => Output.Path.all,
              Stderr_Path       => Errors.Path.all,
              Timeout_Ms        =>
                (if Item.Limit <= 0.0 then 0 else Natural'Max (1, Natural (Item.Limit * 1000))),
              Cancelled         => Item.Cancelled,
              Whole_Group       => True);
         Cut_Out, Cut_Err : Boolean;
      begin
         Result_Of.Started := Happened.Started;
         Result_Of.Stopped := Happened.Timed_Out;
         Result_Of.Exit_Status := Happened.Exit_Status;
         if Happened.Started then
            Read_Bounded (Output.Path.all, Result_Of.Output, Cut_Out);
            Read_Bounded (Errors.Path.all, Result_Of.Errors, Cut_Err);
            Result_Of.Truncated := Cut_Out or else Cut_Err;
         end if;
      end;
      return Result_Of;
   end Run;

   -----------
   -- Told --
   -----------

   function Told (Item : Result; Named : String) return String is
      Output : constant String := U.To_String (Item.Output);
      Errors : constant String := U.To_String (Item.Errors);
   begin
      if not Item.Started then
         return "error: " & Named & " could not be run";
      elsif Succeeded (Item) then
         return (if Output = "" then "(" & Named & " produced no output)" else Output);
      end if;
      return "error: " & Named
        & (if Item.Stopped then " was stopped before it finished"
           else " failed with exit status " & Image (Item.Exit_Status))
        & (if Errors = "" then "" else ASCII.LF & "stderr:" & ASCII.LF & Errors)
        & (if Output = "" then "" else ASCII.LF & "stdout:" & ASCII.LF & Output);
   end Told;

end Model_Runner.Processes;
