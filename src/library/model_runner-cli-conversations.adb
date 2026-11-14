with Ada.Calendar;
with Ada.Calendar.Formatting;
with Ada.Calendar.Time_Zones;
with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

with Model_Runner.CLI.Checkpoint;
with Model_Runner.CLI.Choosers;
with Model_Runner.Conversation;
with Model_Runner.Conversation.Rooms;
with Model_Runner.Errors;
with Model_Runner.Platform;

package body Model_Runner.CLI.Conversations is

   use Ada.Strings.Unbounded;

   function Directory return String is (Model_Runner.Platform.Conversations_Directory);

   --  A time as a person reads it, in this machine's zone.
   function Local_Image (At_Time : Ada.Calendar.Time) return String is
      Offset : Ada.Calendar.Time_Zones.Time_Offset := 0;
   begin
      begin
         Offset := Ada.Calendar.Time_Zones.UTC_Time_Offset (At_Time);
      exception
         when others =>
            Offset := 0;
      end;
      return Ada.Calendar.Formatting.Image (At_Time, Time_Zone => Offset);
   end Local_Image;

   --  A model's name as a file name holds it: the last part, no .gguf.
   function Model_Name (Model : String) return String is
      Cut  : constant Natural := Ada.Strings.Fixed.Index (Model, "/", Ada.Strings.Backward);
      Name : constant String := Model (Cut + 1 .. Model'Last);
   begin
      if Name'Length > 5 and then Name (Name'Last - 4 .. Name'Last) = ".gguf" then
         return Name (Name'First .. Name'Last - 5);
      end if;
      return Name;
   end Model_Name;

   function New_Path (Model : String) return String is
      Dir : constant String := Directory;
   begin
      if Dir = "" then
         return "";
      end if;
      Ada.Directories.Create_Path (Dir);
      declare
         Stamp : String := Local_Image (Ada.Calendar.Clock);
         Name  : String := Model_Name (Model);
      begin
         --  2026-11-14 20:31:05 as 2026-11-14_20-31-05; a name's
         --  separators and spaces kept out of it.
         for C of Stamp loop
            if C = ' ' then
               C := '_';
            elsif C = ':' then
               C := '-';
            end if;
         end loop;
         for C of Name loop
            if C in '/' | '\' | ' ' | ':' then
               C := '_';
            end if;
         end loop;
         return Dir & "/" & Stamp & "--" & Name & ".txt";
      end;
   exception
      when others =>
         return "";
   end New_Path;

   function Sidecar (Conversation : String) return String is (Conversation & ".model");

   procedure Note_Model (Conversation, Model : String) is
      File : Ada.Text_IO.File_Type;
   begin
      Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Sidecar (Conversation), Form => "shared=yes");
      Ada.Text_IO.Put_Line (File, Model);
      Ada.Text_IO.Close (File);
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
   end Note_Model;

   function Model_Of (Conversation : String) return String is
      File : Ada.Text_IO.File_Type;
   begin
      if not Ada.Directories.Exists (Sidecar (Conversation)) then
         return "";
      end if;
      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Sidecar (Conversation), Form => "shared=yes");
      declare
         Line : constant String := Ada.Text_IO.Get_Line (File);
      begin
         Ada.Text_IO.Close (File);
         return Ada.Strings.Fixed.Trim (Line, Ada.Strings.Both);
      end;
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         return "";
   end Model_Of;

   --  The conversations kept, newest first: their files and when each was
   --  last written.
   Most : constant := 200;
   type Kept_Array is array (1 .. Most) of Unbounded_String;
   type Time_Array is array (1 .. Most) of Ada.Calendar.Time;

   procedure Gather (Paths : out Kept_Array; Times : out Time_Array; Count : out Natural) is
      use Ada.Directories;
      use type Ada.Calendar.Time;
      Dir    : constant String := Directory;
      Search : Search_Type;
      Found  : Directory_Entry_Type;
   begin
      Count := 0;
      Times := [others => Ada.Calendar.Clock];
      if Dir = "" or else not Exists (Dir) then
         return;
      end if;
      Start_Search (Search, Dir, "*.txt", Filter => [Ordinary_File => True, others => False]);
      while More_Entries (Search) loop
         Get_Next_Entry (Search, Found);
         declare
            Path : constant String := Full_Name (Found);
            When_Written : constant Ada.Calendar.Time := Modification_Time (Found);
            Slot : Natural := Count + 1;
         begin
            --  In by when it was written, newest first; past Most, the
            --  oldest are left out.
            while Slot > 1 and then Times (Slot - 1) < When_Written loop
               Slot := Slot - 1;
            end loop;
            if Slot <= Most then
               for Move in reverse Slot .. Natural'Min (Count, Most - 1) loop
                  Paths (Move + 1) := Paths (Move);
                  Times (Move + 1) := Times (Move);
               end loop;
               Paths (Slot) := To_Unbounded_String (Path);
               Times (Slot) := When_Written;
               Count := Natural'Min (Count + 1, Most);
            end if;
         end;
      end loop;
      End_Search (Search);
   exception
      when others =>
         null;
   end Gather;

   function Latest return String is
      Paths : Kept_Array;
      Times : Time_Array;
      Count : Natural;
   begin
      Gather (Paths, Times, Count);
      return (if Count = 0 then "" else To_String (Paths (1)));
   end Latest;

   --  A conversation's first message, to tell it by: cut to a line.
   function First_Message (Path : String) return String is
      Room     : Model_Runner.Conversation.Rooms.Holder;
      Messages : Model_Runner.Conversation.History renames Room.Data.all;
      Loaded   : Boolean;
      Status   : Model_Runner.Errors.Error_Info;
      Said     : Unbounded_String;
   begin
      Model_Runner.Conversation.Open (Messages, Status => Status);
      Model_Runner.CLI.Checkpoint.Load (Path, Messages, Loaded, Status, Replace => True);
      if Loaded then
         for Index in 1 .. Model_Runner.Conversation.Length (Messages) loop
            if Model_Runner.Conversation."="
                 (Model_Runner.Conversation.Sender_At (Messages, Index), Model_Runner.Conversation.User_Role)
            then
               Said := To_Unbounded_String (Model_Runner.Conversation.Content_At (Messages, Index));
               exit;
            end if;
         end loop;
      end if;
      Model_Runner.Conversation.Close (Messages);
      declare
         Text : String := To_String (Said);
      begin
         for C of Text loop
            if C < ' ' then
               C := ' ';
            end if;
         end loop;
         return (if Text'Length > 70 then Text (Text'First .. Text'First + 69) & "..." else Text);
      end;
   exception
      when others =>
         return "";
   end First_Message;

   procedure Choose
     (Screen : Model_Runner.Presentation.Console;
      Path   : out Model_Runner.Text.Bounded;
      Picked : out Boolean)
   is
      Paths : Kept_Array;
      Times : Time_Array;
      Count : Natural;
      Items : Model_Runner.CLI.Choosers.Choice_List;
      Taken : Natural;
   begin
      Path := Model_Runner.Text.Empty;
      Picked := False;
      Gather (Paths, Times, Count);
      if Count = 0 then
         return;
      end if;
      for I in 1 .. Count loop
         declare
            File  : constant String := To_String (Paths (I));
            Model : constant String := Model_Of (File);
            Stamp : constant String := Local_Image (Times (I));
         begin
            Model_Runner.CLI.Choosers.Append
              (Items,
               (Label      => To_Unbounded_String
                                (Stamp (Stamp'First .. Stamp'First + 15) & "  "
                                 & First_Message (File)),
                Tag        => To_Unbounded_String (if Model = "" then "" else Model_Name (Model)),
                Details    => To_Unbounded_String (File),
                Selectable => True));
         end;
      end loop;
      Taken := Model_Runner.CLI.Choosers.Choose (Screen, "cli.conversations.choose", Items);
      if Taken in 1 .. Count then
         Path := Model_Runner.Text.To_Bounded (To_String (Paths (Taken)));
         Picked := True;
      end if;
   end Choose;

end Model_Runner.CLI.Conversations;
