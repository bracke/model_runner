with Ada.Containers.Indefinite_Ordered_Sets;
with Ada.Directories;
with Ada.Unchecked_Deallocation;

with Model_Runner.Bytes;
with Model_Runner.Platform.Video;

package body Model_Runner.Video is

   package E renames Model_Runner.Errors;
   package Name_Sets is new Ada.Containers.Indefinite_Ordered_Sets (String);

   use type Model_Runner.Bytes.Byte_Array_Access;

   procedure Free is new Ada.Unchecked_Deallocation
     (Raster_List, Raster_List_Access);
   procedure Free is new Ada.Unchecked_Deallocation
     (Seconds_List, Seconds_List_Access);

   ---------------
   -- Half_Even --
   ---------------

   function Half_Even (X : Long_Float) return Natural is
      Floor : constant Long_Float := Long_Float'Floor (X);
      Rest  : constant Long_Float := X - Floor;
   begin
      if Rest > 0.5 or else (Rest = 0.5 and then Natural (Floor) mod 2 = 1)
      then
         return Natural (Floor) + 1;
      else
         return Natural (Floor);
      end if;
   end Half_Even;

   -------------------
   -- Sampled_Count --
   -------------------

   function Sampled_Count
     (Total : Positive; Rate : Long_Float; Fps : Long_Float) return Positive
   is
      --  The reference's int () cuts towards nought, which for a
      --  positive number is the floor.
      Wanted : constant Natural :=
        (if Rate > 0.0 and then Fps > 0.0
         then Natural (Long_Float'Floor (Long_Float (Total) / Rate * Fps))
         else Total);
   begin
      return Positive'Max
        (1, Natural'Min (Natural'Min (Natural'Max (Wanted, Least_Frames),
                                       Most_Frames),
                         Total));
   end Sampled_Count;

   -------------
   -- Sampled --
   -------------

   function Sampled (Total : Positive; Count : Positive) return Frame_Indices is
      Result : Frame_Indices (1 .. Count);
   begin
      if Count = 1 then
         Result (1) := 0;
         return Result;
      end if;

      --  As numpy's linspace has it: the step, each point the step times
      --  its number, and the last point set to the end exactly.
      declare
         Step : constant Long_Float :=
           Long_Float (Total - 1) / Long_Float (Count - 1);
      begin
         for Which in 1 .. Count loop
            Result (Which) := Half_Even (Long_Float (Which - 1) * Step);
         end loop;
         Result (Count) := Total - 1;
      end;
      return Result;
   end Sampled;

   -------------
   -- Release --
   -------------

   procedure Release
     (Frames : in out Raster_List_Access; Times : in out Seconds_List_Access) is
   begin
      if Frames /= null then
         for Frame of Frames.all loop
            Model_Runner.Images.Free (Frame);
         end loop;
         Free (Frames);
      end if;
      Free (Times);
   end Release;

   --  The pictures a directory holds, in the order their names sort:
   --  every ordinary file in it. What is not a picture is refused when it
   --  is read, by name.
   procedure Frames_Of
     (Directory : String;
      Names     : out Name_Sets.Set;
      Status    : out E.Error_Info)
   is
      use Ada.Directories;
      Search : Search_Type;
      Found  : Directory_Entry_Type;
   begin
      Status := E.Success;
      Names.Clear;
      Start_Search (Search, Directory, "",
                    Filter => [Ordinary_File => True, others => False]);
      while More_Entries (Search) loop
         Get_Next_Entry (Search, Found);
         Names.Include (Full_Name (Found));
      end loop;
      End_Search (Search);
      if Names.Is_Empty then
         Status := E.Make (E.IO_Image_Unreadable);
         E.Add_Text (Status, "path", Directory, E.Param_Path);
         E.Add_Text (Status, "detail", "the directory holds no frames",
                     E.Param_Text);
      end if;
   exception
      when Name_Error | Use_Error =>
         Status := E.Make (E.IO_Open_Failed);
         E.Add_Text (Status, "path", Directory, E.Param_Path);
   end Frames_Of;

   -----------
   -- Fetch --
   -----------

   procedure Fetch
     (Path   : String;
      Fps    : Long_Float;
      Eyes   : Model_Runner.Vision.Encoder;
      Frames : out Raster_List_Access;
      Times  : out Seconds_List_Access;
      Fit_Width, Fit_Height : out Positive;
      Status : out E.Error_Info)
   is
      use type Ada.Directories.File_Kind;

      Count : Natural := 0;

      --  Keep a frame as the Which-th, fitted: the first decides the fit
      --  for all.
      procedure Keep
        (Which : Positive; Frame : in out Model_Runner.Images.Raster) is
      begin
         if Which = 1 then
            Model_Runner.Vision.Frames_Fit
              (Eyes, Frame.Width, Frame.Height, Count, Fit_Width, Fit_Height,
               Status);
            if E.Is_Error (Status) then
               Model_Runner.Images.Free (Frame);
               return;
            end if;
         end if;
         if Frame.Width = Fit_Width and then Frame.Height = Fit_Height then
            Frames.all (Which) := Frame;
            Frame := (others => <>);
         else
            Model_Runner.Images.Resample
              (Frame, Fit_Width, Fit_Height, Frames.all (Which),
               Model_Runner.Images.Cubic);
            Model_Runner.Images.Free (Frame);
            if Frames.all (Which).Pixels = null then
               Status := E.Make (E.Memory_Allocation_Failed);
               E.Add_Text (Status, "category", "video", E.Param_Identifier);
            end if;
         end if;
      end Keep;

      --  Too many frames for one video.
      procedure Too_Many is
      begin
         Status := E.Make (E.CLI_Option_Out_Of_Range);
         E.Add_Text (Status, "option", "--prompt-parts", E.Param_Identifier);
      end Too_Many;

      --  The frames of a directory, the Which-th at (Which - 1) / Fps
      --  seconds.
      procedure Fetch_Pictures is
         Names : Name_Sets.Set;
         Which : Natural := 0;
         Frame : Model_Runner.Images.Raster;
      begin
         Frames_Of (Path, Names, Status);
         if E.Is_Error (Status) then
            return;
         end if;
         Count := Natural (Names.Length);
         if Count > Most_Given then
            Too_Many;
            return;
         end if;
         Frames := new Raster_List (1 .. Count);
         Times := new Seconds_List (1 .. Count);
         for Name of Names loop
            Which := Which + 1;
            Model_Runner.Images.Load (Name, Frame, Status);
            exit when E.Is_Error (Status);
            Keep (Which, Frame);
            exit when E.Is_Error (Status);
            Times.all (Which) := Long_Float (Which - 1) / Fps;
         end loop;
      end Fetch_Pictures;

      --  The frames of a video file, decoded in order and sampled as the
      --  reference samples; the Which-th at its own frame number over the
      --  video's rate. A frame chosen twice, as a short video's are, is
      --  kept twice.
      procedure Fetch_Decoded is
         Reader : Model_Runner.Platform.Video.Reader;
         Frame  : Model_Runner.Images.Raster;
         Done   : Boolean;
         Number : Natural := 0;
         Which  : Natural := 0;
      begin
         if not Ada.Directories.Exists (Path) then
            Status := E.Make (E.IO_Open_Failed);
            E.Add_Text (Status, "path", Path, E.Param_Path);
            return;
         end if;
         Model_Runner.Platform.Video.Open (Reader, Path, Status);
         if E.Is_Error (Status) then
            return;
         end if;
         declare
            Total : constant Positive :=
              Model_Runner.Platform.Video.Frames (Reader);
            Rate  : constant Long_Float :=
              Model_Runner.Platform.Video.Rate (Reader);
            Chosen : constant Frame_Indices :=
              Sampled (Total, Sampled_Count (Total, Rate, Fps));
         begin
            Count := Chosen'Length;
            Frames := new Raster_List (1 .. Count);
            Times := new Seconds_List (1 .. Count);

            while Which < Count loop
               Model_Runner.Platform.Video.Next (Reader, Frame, Done, Status);
               exit when E.Is_Error (Status);
               if Done then
                  Status := E.Make (E.IO_Video_Unreadable);
                  E.Add_Text (Status, "path", Path, E.Param_Path);
                  E.Add_Text
                    (Status, "detail",
                     "the video ended before its stated frames", E.Param_Text);
                  exit;
               end if;
               while Which < Count
                 and then Chosen (Chosen'First + Which) = Number
               loop
                  Which := Which + 1;
                  if Which < Count
                    and then Chosen (Chosen'First + Which) = Number
                  then
                     declare
                        Copy : Model_Runner.Images.Raster;
                     begin
                        Model_Runner.Images.Resample
                          (Frame, Frame.Width, Frame.Height, Copy,
                           Model_Runner.Images.Cubic);
                        Keep (Which, Copy);
                     end;
                  else
                     Keep (Which, Frame);
                  end if;
                  exit when E.Is_Error (Status);
                  Times.all (Which) := Long_Float (Number) / Rate;
               end loop;
               Model_Runner.Images.Free (Frame);
               exit when E.Is_Error (Status);
               Number := Number + 1;
            end loop;
         end;
         Model_Runner.Platform.Video.Close (Reader);
      end Fetch_Decoded;
   begin
      Frames := null;
      Times := null;
      Fit_Width := 1;
      Fit_Height := 1;
      Status := E.Success;

      if not Model_Runner.Vision.Reads_Video (Eyes) then
         Status := E.Make (E.Arch_Unsupported_Feature);
         E.Add_Text (Status, "feature", "video", E.Param_Identifier);
         return;
      end if;

      if Ada.Directories.Exists (Path)
        and then Ada.Directories.Kind (Path) = Ada.Directories.Directory
      then
         Fetch_Pictures;
      else
         Fetch_Decoded;
      end if;

      if E.Is_Error (Status) then
         Release (Frames, Times);
      end if;
   end Fetch;

end Model_Runner.Video;
