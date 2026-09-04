with Ada.Directories;
with Ada.Text_IO;

package body Device_Clock is

   --  Where the kernel says what an AMD device is doing. The card number is
   --  not fixed -- a host with a display and a compute part has two, and
   --  which is which is the host's business -- so the one that answers is
   --  the one that has the file.
   Cards : constant := 8;

   --  How often to look while a run is going.
   --
   --  The instrument has to cost nothing it is measuring, and this one was
   --  measured rather than assumed. Reading the clock is not a file read:
   --  the driver asks the part, and at a hundredth of a second -- with the
   --  kernel's directories searched at every sample as well -- a
   --  1419-token prompt read 1.492 s against 1.477, one per cent and
   --  consistently. Resolving the paths once took it to 0.7 per cent and a
   --  twentieth of a second took it under what the measurement resolves.
   --
   --  A twentieth is still thirty samples of that prompt and six of a
   --  twelve-token generation, which is enough to say what a part held and
   --  not enough to say when.
   Every : constant Duration := 0.05;

   --  Where the clock states are, for card N.
   function Clock_File (Card : Natural) return String
   is ("/sys/class/drm/card"
       & Natural'Image (Card) (2 .. Natural'Image (Card)'Last)
       & "/device/pp_dpm_sclk");

   --  Which card answers, or minus one.
   function Answering return Integer;

   --  Where that card says what it is drawing, or the empty string.
   function Power_File (Card : Integer) return String;

   --  The megahertz in a line like "1: 2700Mhz *", or zero.
   function Megahertz (Line : String) return Natural;

   ----------------
   -- Megahertz --
   ----------------

   function Megahertz (Line : String) return Natural is
      From : Natural := Line'First;
      Stop : Natural;
   begin
      --  Past the state number and its colon.
      while From <= Line'Last and then Line (From) /= ':' loop
         From := From + 1;
      end loop;

      From := From + 1;

      while From <= Line'Last and then Line (From) = ' ' loop
         From := From + 1;
      end loop;

      Stop := From;
      while Stop <= Line'Last
        and then Line (Stop) in '0' .. '9'
      loop
         Stop := Stop + 1;
      end loop;

      if Stop = From then
         return 0;
      end if;

      return Natural'Value (Line (From .. Stop - 1));
   exception
      when others =>
         return 0;
   end Megahertz;

   -----------------
   -- Answering --
   -----------------

   function Answering return Integer is
   begin
      for Card in 0 .. Cards - 1 loop
         if Ada.Directories.Exists (Clock_File (Card)) then
            return Card;
         end if;
      end loop;

      return -1;
   end Answering;

   ------------------
   -- Power_File --
   ------------------

   function Power_File (Card : Integer) return String is
      Root : constant String :=
        "/sys/class/drm/card"
        & Natural'Image (Card) (2 .. Natural'Image (Card)'Last)
        & "/device/hwmon";

      Search : Ada.Directories.Search_Type;
      Found  : Ada.Directories.Directory_Entry_Type;
   begin
      if Card < 0 or else not Ada.Directories.Exists (Root) then
         return "";
      end if;

      Ada.Directories.Start_Search
        (Search, Root, "hwmon*",
         [Ada.Directories.Directory => True, others => False]);

      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Found);

         declare
            Where : constant String :=
              Ada.Directories.Full_Name (Found) & "/power1_average";
         begin
            if Ada.Directories.Exists (Where) then
               Ada.Directories.End_Search (Search);
               return Where;
            end if;
         end;
      end loop;

      Ada.Directories.End_Search (Search);
      return "";
   exception
      when others =>
         return "";
   end Power_File;

   --  Resolved once, because a sampler that searched the kernel's
   --  directories every twentieth of a second would be measuring itself:
   --  the searching, and not the reading, is what cost one per cent of a
   --  prompt when this was first written.
   Card_Now  : constant Integer := Answering;
   Clock_At  : constant String :=
     (if Card_Now >= 0 then Clock_File (Card_Now) else "");
   Power_At  : constant String := Power_File (Card_Now);

   --------------
   -- Offered --
   --------------

   function Offered return Boolean is (Clock_At /= "");

   --  What the part is drawing, in watts, or zero.
   function Watts_Now return Long_Float;

   function Watts_Now return Long_Float is
      Handle : Ada.Text_IO.File_Type;
   begin
      if Power_At = "" then
         return 0.0;
      end if;

      Ada.Text_IO.Open (Handle, Ada.Text_IO.In_File, Power_At);

      declare
         --  Microwatts, which is what the kernel keeps it in.
         Line : constant String := Ada.Text_IO.Get_Line (Handle);
      begin
         Ada.Text_IO.Close (Handle);
         return Long_Float'Value (Line) / 1_000_000.0;
      end;
   exception
      when others =>
         if Ada.Text_IO.Is_Open (Handle) then
            Ada.Text_IO.Close (Handle);
         end if;
         return 0.0;
   end Watts_Now;

   ----------
   -- Look --
   ----------

   function Look return Reading is
      Handle : Ada.Text_IO.File_Type;
      Got    : Reading;
   begin
      if Clock_At = "" then
         return Got;
      end if;

      Ada.Text_IO.Open (Handle, Ada.Text_IO.In_File, Clock_At);

      while not Ada.Text_IO.End_Of_File (Handle) loop
         declare
            Line : constant String := Ada.Text_IO.Get_Line (Handle);
            Rate : constant Natural := Megahertz (Line);
         begin
            if Rate > 0 then
               --  The last state named is the highest the part offers, and
               --  the starred one is where it is now.
               Got.Top := Natural'Max (Got.Top, Rate);

               for Index in Line'Range loop
                  if Line (Index) = '*' then
                     Got.Mean := Rate;
                     Got.Least := Rate;
                     Got.Most := Rate;
                     Got.Samples := 1;
                     Got.Seen := True;
                     exit;
                  end if;
               end loop;
            end if;
         end;
      end loop;

      Ada.Text_IO.Close (Handle);

      if Got.Seen then
         Got.Watts := Watts_Now;
      end if;

      return Got;
   exception
      when others =>
         if Ada.Text_IO.Is_Open (Handle) then
            Ada.Text_IO.Close (Handle);
         end if;
         return (others => <>);
   end Look;

   -----------
   -- Shown --
   -----------

   function Shown (Of_Reading : Reading) return String is
      function Rate (Value : Natural) return String
      is (Natural'Image (Value) (2 .. Natural'Image (Value)'Last));

      function Two (Value : Long_Float) return String is
         Whole : constant Natural := Natural (Long_Float'Floor (Value));
         Parts : constant Natural :=
           Natural (Long_Float'Floor ((Value - Long_Float (Whole)) * 10.0));
      begin
         return Rate (Whole) & "." & Rate (Parts);
      end Two;
   begin
      if not Of_Reading.Seen or else Of_Reading.Samples = 0 then
         return "";
      end if;

      return "; device " & Rate (Of_Reading.Mean) & " MHz mean of "
        & Rate (Of_Reading.Top) & ", " & Rate (Of_Reading.Least)
        & " to " & Rate (Of_Reading.Most)
        & (if Of_Reading.Watts > 0.0
           then " at " & Two (Of_Reading.Watts) & " W" else "");
   end Shown;

   -------------
   -- Watcher --
   -------------

   task body Watcher is
      Got   : Reading;
      Total : Long_Float := 0.0;
      Power : Long_Float := 0.0;
      Done  : Boolean := False;
      Awake : Boolean := False;
   begin
      accept Start (Watching : Boolean) do
         Awake := Watching;
      end Start;

      if not Awake then
         accept Stop (Got : out Reading) do
            Got := (others => <>);
         end Stop;

         Done := True;
      end if;

      Got.Least := Natural'Last;

      while not Done loop
         select
            accept Stop (Got : out Reading) do
               Done := True;

               if Total > 0.0 and then Watcher.Got.Samples > 0 then
                  Watcher.Got.Mean :=
                    Natural (Total / Long_Float (Watcher.Got.Samples));
                  Watcher.Got.Watts :=
                    Power / Long_Float (Watcher.Got.Samples);
               else
                  --  Nothing was seen, so nothing is claimed.
                  Watcher.Got.Least := 0;
               end if;

               Got := Watcher.Got;
            end Stop;
         or
            delay Every;

            declare
               Now : constant Reading := Look;
            begin
               if Now.Seen then
                  Got.Seen := True;
                  Got.Top := Natural'Max (Got.Top, Now.Top);
                  Got.Least := Natural'Min (Got.Least, Now.Mean);
                  Got.Most := Natural'Max (Got.Most, Now.Mean);
                  Got.Samples := Got.Samples + 1;
                  Total := Total + Long_Float (Now.Mean);
                  Power := Power + Now.Watts;
               end if;
            end;
         end select;
      end loop;
   exception
      --  A watcher that failed is a figure without a clock, not a failed
      --  run: the caller is waiting on Stop and has to be let go.
      when others =>
         select
            accept Stop (Got : out Reading) do
               Got := (others => <>);
            end Stop;
         or
            delay 5.0;
         end select;
   end Watcher;

end Device_Clock;
