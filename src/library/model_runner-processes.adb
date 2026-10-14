with Ada.Directories;
with Ada.Finalization;
with Ada.IO_Exceptions;
with Ada.Streams.Stream_IO;
with Ada.Task_Attributes;

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

   --  What the run now going on this task is held to: the files it writes
   --  what it says into, the most it may say, and the stop it was asked.
   type Bound is record
      Out_Path, Err_Path : U.Unbounded_String;
      Asked              : Hostkit.Process.Cancel_Check := null;
      Overflowed         : Boolean := False;
   end record;
   type Bound_Access is access Bound;
   package Task_Bounds is new Ada.Task_Attributes (Bound_Access, null);

   --  The most a program run for a tool may say before it is stopped: what
   --  it writes goes to temporary files, and is not let fill their disk.
   Most_Said : constant := 256 * 1024 * 1024;

   function Bounded_Stop return Boolean is
      Mine : constant Bound_Access := Task_Bounds.Value;
      use type Ada.Directories.File_Size;

      function Too_Big (Path : String) return Boolean is
      begin
         return Path /= "" and then Ada.Directories.Exists (Path) and then Ada.Directories.Size (Path) > Most_Said;
      exception
         --  Gone or not to be looked at as it is asked: not too big for it.
         when Ada.IO_Exceptions.Name_Error | Ada.IO_Exceptions.Use_Error =>
            return False;
      end Too_Big;
   begin
      if Mine = null then
         return False;
      end if;
      if Too_Big (U.To_String (Mine.Out_Path)) or else Too_Big (U.To_String (Mine.Err_Path)) then
         Mine.Overflowed := True;
      end if;
      return Mine.Overflowed or else (Hostkit.Process."/=" (Mine.Asked, null) and then Mine.Asked.all);
   end Bounded_Stop;

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
         Mine : Bound_Access := Task_Bounds.Value;
         function Held_Stop return Hostkit.Process.Cancel_Check is
         begin
            if Mine = null then
               Mine := new Bound;
               Task_Bounds.Set_Value (Mine);
            end if;
            Mine.all := (Out_Path => U.To_Unbounded_String (Output.Path.all),
                         Err_Path => U.To_Unbounded_String (Errors.Path.all),
                         Asked => Item.Cancelled, Overflowed => False);
            return Bounded_Stop'Access;
         end Held_Stop;
         Happened : constant Hostkit.Process.Process_Outcome :=
           Hostkit.Process.Run_Captured
             (Program           => Where,
              Arguments         => Item.Arguments,
              Working_Directory => U.To_String (Item.Directory),
              Stdout_Path       => Output.Path.all,
              Stderr_Path       => Errors.Path.all,
              Timeout_Ms        =>
                (if Item.Limit <= 0.0 then 0 else Natural'Max (1, Natural (Item.Limit * 1000))),
              Cancelled         => Held_Stop,
              Whole_Group       => True);
         Cut_Out, Cut_Err : Boolean;
      begin
         Result_Of.Started := Happened.Started;
         Result_Of.Stopped := Happened.Timed_Out;
         Result_Of.Exit_Status := Happened.Exit_Status;
         if Happened.Started then
            Read_Bounded (Output.Path.all, Result_Of.Output, Cut_Out);
            Read_Bounded (Errors.Path.all, Result_Of.Errors, Cut_Err);
            --  Stopped for saying too much: cut short, and said so.
            Result_Of.Truncated := Cut_Out or else Cut_Err or else (Mine /= null and then Mine.Overflowed);
         end if;
         if Mine /= null then
            Mine.all := (others => <>);
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

      function Kept (Text : String) return String is
         Head : constant Natural := Told_Most * 3 / 5;
         Tail : constant Natural := Told_Most - Head - 64;
      begin
         if Text'Length <= Told_Most then
            return Text;
         end if;
         return Text (Text'First .. Text'First + Head - 1) & ASCII.LF & "...["
           & Image (Text'Length - Head - Tail) & " bytes left out]..." & ASCII.LF
           & Text (Text'Last - Tail + 1 .. Text'Last);
      end Kept;
   begin
      if not Item.Started then
         return "error: " & Named & " could not be run";
      elsif Succeeded (Item) then
         return Kept (if Output = "" then "(" & Named & " produced no output)" else Output);
      end if;
      return Kept ("error: " & Named
        & (if Item.Stopped then " was stopped before it finished"
           else " failed with exit status " & Image (Item.Exit_Status))
        & (if Errors = "" then "" else ASCII.LF & "stderr:" & ASCII.LF & Errors)
        & (if Output = "" then "" else ASCII.LF & "stdout:" & ASCII.LF & Output));
   end Told;

end Model_Runner.Processes;
