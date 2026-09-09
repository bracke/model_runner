with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Text_IO;

with Model_Runner.Text;

package body Host_Load is

   Where : constant String := "/proc/loadavg";

   --  Where the processors say what they have been doing, and how long to
   --  watch them. A fifth of a second is long enough to see a busy core and
   --  short enough that a gate polled once a second does not notice it.
   Ticks_At : constant String := "/proc/stat";
   Window   : constant Duration := 0.2;

   --  Where the host says how warm its parts are, and which of them are
   --  parts a figure waits on.
   --
   --  A list of drivers rather than every sensor the host has, because a
   --  host has sensors for things a timing does not wait on: this one
   --  reports a disk at 60 degrees and two memory modules beside the
   --  processor, and a gate that took the highest of everything would be
   --  refusing figures because a disk was warm. A host whose processor is
   --  behind a name that is not on this list has no thermometer as far as
   --  this is concerned, which is the same answer it gave before there was
   --  one.
   Sensors_At : constant String := "/sys/class/hwmon";

   subtype Driver_Name is String (1 .. 12);
   type Name_List is array (Positive range <>) of Driver_Name;

   Watched : constant Name_List :=
     ["k10temp     ",   --  AMD processors
      "zenpower    ",   --  and the other driver for them
      "coretemp    ",   --  Intel processors
      "cpu_thermal ",   --  the usual name on ARM
      "amdgpu      ",   --  AMD devices, integrated and not
      "i915        ",   --  Intel devices
      "xe          ",   --  and their newer driver
      "nouveau     "];  --  NVIDIA, where the free driver runs it

   --  How many processors were busy over the window, and how many there
   --  are. Busy is everything that is not idle and not waiting on a disk.
   --
   --  Negative where the host does not keep these numbers, which is not the
   --  same as zero: zero is a quiet machine and negative is one that did
   --  not say.
   function Busy_Processors return Long_Float;

   --  What one file holds, with nothing in it read as nothing said.
   function First_Line (Named : String) return String;

   function First_Line (Named : String) return String is
      Handle : Ada.Text_IO.File_Type;
   begin
      if not Ada.Directories.Exists (Named) then
         return "";
      end if;

      Ada.Text_IO.Open (Handle, Ada.Text_IO.In_File, Named);

      declare
         Line : constant String :=
           (if Ada.Text_IO.End_Of_File (Handle) then ""
            else Ada.Text_IO.Get_Line (Handle));
      begin
         Ada.Text_IO.Close (Handle);
         return Line;
      end;
   exception
      when others =>
         if Ada.Text_IO.Is_Open (Handle) then
            Ada.Text_IO.Close (Handle);
         end if;
         return "";
   end First_Line;

   -------------------
   -- Quiet_Enough --
   -------------------

   function Quiet_Enough return Boolean is
      Quiet      : Boolean;
      Reading    : Long_Float;
      Processors : Boolean;
   begin
      Look (Quiet, Reading, Processors);
      return Quiet;
   end Quiet_Enough;

   ------------------
   -- Processors --
   ------------------

   function Processors return Natural is
      Handle : Ada.Text_IO.File_Type;
      Seen   : Natural := 0;
   begin
      if not Ada.Directories.Exists (Ticks_At) then
         return 0;
      end if;

      Ada.Text_IO.Open (Handle, Ada.Text_IO.In_File, Ticks_At);

      while not Ada.Text_IO.End_Of_File (Handle) loop
         declare
            Line : constant String := Ada.Text_IO.Get_Line (Handle);
         begin
            exit when Line'Length < 4
              or else Line (Line'First .. Line'First + 2) /= "cpu";

            --  "cpu" alone is the total; "cpu0" and its fellows are the
            --  processors, and only those are counted.
            if Line (Line'First + 3) /= ' ' then
               Seen := Seen + 1;
            end if;
         end;
      end loop;

      Ada.Text_IO.Close (Handle);
      return Seen;
   exception
      when others =>
         if Ada.Text_IO.Is_Open (Handle) then
            Ada.Text_IO.Close (Handle);
         end if;
         return 0;
   end Processors;

   ----------------
   -- Too_Busy --
   ----------------

   function Too_Busy return Long_Float is
   begin
      return Long_Float'Max (0.25, Long_Float (Processors) / 20.0);
   end Too_Busy;

   -------------
   -- Warmth --
   -------------

   function Warmth return Long_Float is
      Search : Ada.Directories.Search_Type;
      Found  : Ada.Directories.Directory_Entry_Type;
      Hottest : Long_Float := -1.0;
   begin
      if not Ada.Directories.Exists (Sensors_At) then
         return -1.0;
      end if;

      Ada.Directories.Start_Search
        (Search, Sensors_At, "", [Ada.Directories.Directory => True,
                                  others => False]);

      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Found);

         declare
            Here : constant String := Ada.Directories.Full_Name (Found);
            Name : constant String := First_Line (Here & "/name");
            Wanted : Boolean := False;
         begin
            for Which of Watched loop
               Wanted := Wanted
                 or else Name
                         = Ada.Strings.Fixed.Trim
                             (Which, Ada.Strings.Right);
            end loop;

            if Wanted then
               declare
                  --  The first sensor of the part rather than the hottest
                  --  of its sensors: on this driver that is Tctl for the
                  --  processor and the edge for the device, which are the
                  --  two a datasheet quotes and the two a person reads.
                  Text : constant String := First_Line (Here & "/temp1_input");
               begin
                  if Text /= "" then
                     Hottest :=
                       Long_Float'Max
                         (Hottest, Long_Float'Value (Text) / 1000.0);
                  end if;
               end;
            end if;
         end;
      end loop;

      Ada.Directories.End_Search (Search);
      return Hottest;
   exception
      when others =>
         return -1.0;
   end Warmth;

   ----------
   -- Look --
   ----------

   procedure Look
     (Quiet      : out Boolean;
      Reading    : out Long_Float;
      Processors : out Boolean)
   is
      Busy : constant Long_Float := Busy_Processors;
   begin
      --  Where the processors say, they decide, because they are answering
      --  about now and the average is answering about the minute behind.
      if Busy >= 0.0 then
         Quiet      := Busy <= Too_Busy;
         Reading    := Busy;
         Processors := True;
         return;
      end if;

      --  A host that keeps no per-processor times has only the average, and
      --  is left exactly where it was before this existed.
      Reading    := Now;
      Quiet      := Publishable (Reading);
      Processors := False;
   end Look;

   ----------------------
   -- Busy_Processors --
   ----------------------

   function Busy_Processors return Long_Float is
      type Sample is record
         Whole : Long_Float := 0.0;
         Spare : Long_Float := 0.0;
         Count : Natural    := 0;
      end record;

      --  The first line totals every processor and the lines after it name
      --  one each, so the count comes from the same read as the times.
      --  Fields are user, nice, system, idle, iowait and on; the fourth and
      --  fifth are the two that are not work.
      Idle_Field   : constant := 4;
      Iowait_Field : constant := 5;

      function Taken return Sample is
         Handle : Ada.Text_IO.File_Type;
         Got    : Sample;
      begin
         Ada.Text_IO.Open (Handle, Ada.Text_IO.In_File, Ticks_At);

         while not Ada.Text_IO.End_Of_File (Handle) loop
            declare
               Line : constant String := Ada.Text_IO.Get_Line (Handle);
            begin
               exit when Line'Length < 4
                 or else Line (Line'First .. Line'First + 2) /= "cpu";

               --  "cpu" alone is the total; "cpu0" and its fellows are the
               --  processors, and only those are counted.
               if Line (Line'First + 3) /= ' ' then
                  Got.Count := Got.Count + 1;
               else
                  declare
                     From : Natural := Line'First + 3;
                     Seen : Natural := 0;
                  begin
                     while From <= Line'Last loop
                        while From <= Line'Last
                          and then Line (From) = ' '
                        loop
                           From := From + 1;
                        end loop;
                        exit when From > Line'Last;

                        declare
                           Stop : Natural := From;
                        begin
                           while Stop <= Line'Last
                             and then Line (Stop) /= ' '
                           loop
                              Stop := Stop + 1;
                           end loop;

                           declare
                              Field : constant Long_Float :=
                                Long_Float'Value (Line (From .. Stop - 1));
                           begin
                              Seen := Seen + 1;
                              Got.Whole := Got.Whole + Field;

                              if Seen = Idle_Field
                                or else Seen = Iowait_Field
                              then
                                 Got.Spare := Got.Spare + Field;
                              end if;
                           end;

                           From := Stop;
                        end;
                     end loop;
                  end;
               end if;
            end;
         end loop;

         Ada.Text_IO.Close (Handle);
         return Got;
      end Taken;

      First, Then_On : Sample;
   begin
      if not Ada.Directories.Exists (Ticks_At) then
         return -1.0;
      end if;

      First := Taken;
      delay Window;
      Then_On := Taken;

      if First.Count = 0 or else Then_On.Count /= First.Count then
         return -1.0;
      end if;

      declare
         Whole : constant Long_Float := Then_On.Whole - First.Whole;
         Spare : constant Long_Float := Then_On.Spare - First.Spare;
      begin
         --  A window in which no processor did anything at all, not even
         --  idle, is a window this did not measure.
         if Whole <= 0.0 or else Spare < 0.0 or else Spare > Whole then
            return -1.0;
         end if;

         return Long_Float (First.Count) * (Whole - Spare) / Whole;
      end;
   exception
      when others =>
         return -1.0;
   end Busy_Processors;

   ---------------------
   -- Wait_For_Quiet --
   ---------------------

   function Wait_For_Quiet
     (Minutes : Natural;
      Say     : access procedure (Load : Long_Float) := null) return Boolean
   is
      Looks : constant Natural := Minutes * 60;

      --  The number the gate decided on, so that a caller shown "it is at"
      --  is shown the same instrument the bound is in.
      Quiet      : Boolean;
      Seen       : Long_Float;
      Processors : Boolean;
   begin
      Look (Quiet, Seen, Processors);

      if Quiet then
         return True;
      end if;

      for Turn in 1 .. Looks loop
         if Say /= null then
            Say (Seen);
         end if;

         delay 1.0;
         Look (Quiet, Seen, Processors);

         if Quiet then
            return True;
         end if;
      end loop;

      return False;
   end Wait_For_Quiet;

   ------------------------
   -- Processor_Seconds --
   ------------------------

   function Processor_Seconds return Long_Float is
      Where : constant String := "/proc/self/stat";
      Handle : Ada.Text_IO.File_Type;

      --  User and system ticks are the fourteenth and fifteenth fields, and
      --  the ticks a second are a hundred on every host this runs on. The
      --  process name is the second field and can hold spaces inside its
      --  brackets, so the count starts after the closing bracket rather
      --  than at the beginning of the line.
      User_Field : constant := 14;
      Sys_Field  : constant := 15;
      Per_Second : constant := 100.0;
   begin
      if not Ada.Directories.Exists (Where) then
         return 0.0;
      end if;

      Ada.Text_IO.Open (Handle, Ada.Text_IO.In_File, Where);

      declare
         Line : constant String := Ada.Text_IO.Get_Line (Handle);
         From : Natural := Line'First;
         Seen : Natural := 2;
         Ticks : Long_Float := 0.0;
      begin
         Ada.Text_IO.Close (Handle);

         --  Past the bracketed name.
         while From <= Line'Last and then Line (From) /= ')' loop
            From := From + 1;
         end loop;

         while From <= Line'Last loop
            while From <= Line'Last and then Line (From) = ' ' loop
               From := From + 1;
            end loop;
            exit when From > Line'Last;

            declare
               Stop : Natural := From;
            begin
               while Stop <= Line'Last and then Line (Stop) /= ' ' loop
                  Stop := Stop + 1;
               end loop;

               Seen := Seen + 1;
               if Seen = User_Field or else Seen = Sys_Field then
                  Ticks := Ticks
                    + Long_Float'Value (Line (From .. Stop - 1));
               end if;

               exit when Seen > Sys_Field;
               From := Stop;
            end;
         end loop;

         return Ticks / Per_Second;
      end;
   exception
      when others =>
         if Ada.Text_IO.Is_Open (Handle) then
            Ada.Text_IO.Close (Handle);
         end if;
         return 0.0;
   end Processor_Seconds;

   ---------
   -- Now --
   ---------

   function Now return Long_Float is
      Handle : Ada.Text_IO.File_Type;
   begin
      if not Ada.Directories.Exists (Where) then
         return 0.0;
      end if;

      Ada.Text_IO.Open (Handle, Ada.Text_IO.In_File, Where);

      declare
         Line : constant String := Ada.Text_IO.Get_Line (Handle);
         Stop : Natural := Line'First;
      begin
         Ada.Text_IO.Close (Handle);

         --  The first field, which is the minute's average. The rest of the
         --  line is the five and fifteen minute averages and a count of
         --  processes, none of which says anything about a run that takes
         --  seconds.
         while Stop <= Line'Last and then Line (Stop) /= ' ' loop
            Stop := Stop + 1;
         end loop;

         return Long_Float'Value (Line (Line'First .. Stop - 1));
      end;
   exception
      --  A host that has the file and will not give it up is a host that
      --  keeps no load average as far as this is concerned.
      when others =>
         if Ada.Text_IO.Is_Open (Handle) then
            Ada.Text_IO.Close (Handle);
         end if;
         return 0.0;
   end Now;

   -------------
   -- Settle --
   -------------

   function Settle (Minutes : Natural; Anyway : Boolean) return Boolean is
      --  Once every thirty looks rather than every one, because a machine
      --  that takes ten minutes to go quiet should say so a few times and
      --  not six hundred.
      Told : Natural := 0;

      procedure Still (Load : Long_Float) is
      begin
         if Told mod 30 = 0 then
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "waiting for the machine to fall below "
               & Model_Runner.Text.Image (Too_Busy, 2)
               & "; it is at " & Model_Runner.Text.Image (Load, 2));
         end if;
         Told := Told + 1;
      end Still;
   begin
      if Anyway then
         return True;
      end if;

      if Minutes > 0 then
         if Wait_For_Quiet (Minutes, Still'Unrestricted_Access) then
            return True;
         end if;

         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error,
            "the machine did not fall below "
            & Model_Runner.Text.Image (Too_Busy, 2)
            & " within" & Natural'Image (Minutes)
            & " minutes; nothing measured");
         return False;
      end if;

      --  Quiet_Enough and not Publishable, because this asks whether a
      --  figure may be taken NOW and the average answers about the minute
      --  behind: it lags the window a run is about to occupy.
      declare
         Quiet      : Boolean;
         Reading    : Long_Float;
         Processors : Boolean;
      begin
         Look (Quiet, Reading, Processors);

         if Quiet then
            return True;
         end if;

         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error,
            (if Processors
             then "the machine has " & Model_Runner.Text.Image (Reading, 2)
               & " processors busy, above the "
             else "the machine is at a load of "
               & Model_Runner.Text.Image (Reading, 2) & ", above the ")
            & Model_Runner.Text.Image (Too_Busy, 2)
            & " a figure worth publishing needs; wait, or pass "
            & "--anyway for the shape of the answer");
         return False;
      end;
   end Settle;

end Host_Load;
