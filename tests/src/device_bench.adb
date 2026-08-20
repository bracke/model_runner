with Ada.Calendar;
with Ada.Text_IO;

with Model_Runner.Numerics;
with Model_Runner.Platform.Device.Products;
with Model_Runner.Platform.Device;

package body Device_Bench is

   package N renames Model_Runner.Numerics;
   package Devices renames Model_Runner.Platform.Device;
   package Products renames Model_Runner.Platform.Device.Products;

   ------------
   -- Report --
   ------------

   procedure Report is
      use type Ada.Calendar.Time;

      Held   : Devices.Inventory;
      Found  : Boolean;
      Opened : Devices.Context;
      Engine : Products.Engine;
      Ready  : Boolean;

      Rounds : constant := 20;

      --  Time one shape and say what it cost, per call and per position.
      procedure Take (Heads : Natural; Wide : Natural; Steps : Natural);

      procedure Take (Heads : Natural; Wide : Natural; Steps : Natural) is
         use type N.Element_Count;

         Span  : constant Natural := Heads * Wide;

         --  On the heap: a cache of two thousand positions across
         --  thirty-two heads is thirty-two megabytes, which is a stack
         --  overflow rather than a benchmark.
         type Values is access N.Real_Array;

         Cache : constant Values :=
           new N.Real_Array
             (0 .. N.Element_Count (Steps) * N.Element_Count (Span) * 2 - 1);
         Asked : constant Values :=
           new N.Real_Array (0 .. N.Element_Count (Span) - 1);
         Got   : constant Values :=
           new N.Real_Array (0 .. N.Element_Count (Span) - 1);

         Started : Ada.Calendar.Time;
         Spent   : Duration;
         Ok      : Boolean;

         --  Two multiply-adds a component of a key, and two a component of a
         --  value, for every head and every position.
         Work : constant Long_Float :=
           4.0 * Long_Float (Heads) * Long_Float (Wide) * Long_Float (Steps);
      begin
         Cache.all := [others => 0.125];
         Asked.all := [others => 0.25];

         --  The cache put there once, as a layer would: a position is
         --  written when it is computed, not re-sent for every call that
         --  reads it. What is timed below is the kernel and nothing else.
         Products.Reserve (Engine, Cache.all'Length, Ok);
         if not Ok then
            Ada.Text_IO.Put_Line ("  no room for the cache");
            return;
         end if;

         Products.Put_Cache (Engine, 0, Cache.all, Ok);
         if not Ok then
            Ada.Text_IO.Put_Line ("  the cache would not be written");
            return;
         end if;

         Started := Ada.Calendar.Clock;

         for Round in 1 .. Rounds loop
            Products.Attend_Resident
              (Engine, Asked.all,
               Heads => Heads, Head_Size => Wide, Value_Size => Wide,
               Group_Size => 1, First => 0, Last => Steps - 1,
               K_Base => 0, V_Base => Steps * Span,
               KV_Width => Span, V_Width => Span,
               Scale => 0.125, Cap => 0.0, Target => Got.all, Ok => Ok);
            exit when not Ok;
         end loop;

         Spent := (Ada.Calendar.Clock - Started) / Rounds;

         --  And what writing one position into that cache costs, which is
         --  what a layer does twice a token and what stood between the
         --  kernel's time and the engine's.
         declare
            Row     : constant N.Real_Array (0 .. N.Element_Count (Span) - 1)
              := [others => 0.5];
            Writing : Ada.Calendar.Time;
            Each    : Duration;
         begin
            Writing := Ada.Calendar.Clock;
            for Round in 1 .. Rounds * 10 loop
               Products.Put_Cache (Engine, 0, Row, Ok);
            end loop;
            Each := (Ada.Calendar.Clock - Writing) / (Rounds * 10);

            Ada.Text_IO.Put_Line
              ("    a cache write of" & Natural'Image (Span) & " values:"
               & Duration'Image (Each) & " s");
         end;

         Ada.Text_IO.Put_Line
           ("  heads" & Natural'Image (Heads)
            & ", wide" & Natural'Image (Wide)
            & ", positions" & Natural'Image (Steps)
            & (if Ok then "" else "  REFUSED")
            & " :" & Duration'Image (Spent) & " s a call, "
            & Long_Float'Image (Work / Long_Float (Spent) / 1.0E9)
            & " Gflop/s, cache"
            & Natural'Image (Natural (Cache.all'Length) / 256) & " KiB");
      end Take;
   begin
      Devices.Open (Held, Found);
      if not Found or else Devices.Count (Held) = 0 then
         Ada.Text_IO.Put_Line ("no device here");
         return;
      end if;

      Devices.Open (Opened, Held, 1, Ready);
      if Ready then
         Products.Open (Engine, Opened, Ready);
      end if;

      if not Ready then
         Ada.Text_IO.Put_Line ("no device here");
         Devices.Close (Held);
         return;
      end if;

      Ada.Text_IO.Put_Line ("attention, median of" & Natural'Image (Rounds)
                            & " calls a shape:");

      --  Few positions and many, at one head and at thirty-two. A cost that
      --  hardly moves between the first two is a cost that is not the
      --  arithmetic.
      Take (1, 64, 16);
      Take (1, 64, 512);
      Take (32, 64, 16);
      Take (32, 64, 512);
      Take (32, 64, 2048);

      Products.Close (Engine);
      Devices.Close (Opened);
      Devices.Close (Held);
   end Report;

end Device_Bench;
