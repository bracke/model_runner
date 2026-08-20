with Ada.Calendar;
with Ada.Text_IO;

with Model_Runner.Bytes;
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
      procedure Take
        (Heads   : Natural;
         Wide    : Natural;
         Steps   : Natural;
         Sharing : Natural := 1;
         Layers  : Natural := 1;
         Room    : Natural := 0);

      --  The engine's own shape, not a tidy one. A model with grouped
      --  queries has fewer key heads than query heads, so a position's keys
      --  are narrower than its queries, and the cache holds every layer of
      --  the whole context rather than the few positions being attended to.
      --  Both of those change what the kernel reads and neither was in the
      --  first shapes measured here.
      procedure Take
        (Heads   : Natural;
         Wide    : Natural;
         Steps   : Natural;
         Sharing : Natural := 1;
         Layers  : Natural := 1;
         Room    : Natural := 0)
      is
         use type N.Element_Count;

         --  How wide one position's keys are: a group a head unless heads
         --  share, and then a group per group.
         Groups : constant Natural := Heads / Sharing;
         Narrow : constant Natural := Groups * Wide;

         Span  : constant Natural := Heads * Wide;

         --  How many positions the cache has room for, against how many are
         --  attended to. A layer of a real model holds the whole context.
         Kept  : constant Natural := (if Room = 0 then Steps else Room);

         --  On the heap: a cache of two thousand positions across
         --  thirty-two heads is thirty-two megabytes, which is a stack
         --  overflow rather than a benchmark.
         type Values is access N.Real_Array;

         Cache : constant Values :=
           new N.Real_Array
             (0 .. N.Element_Count (Layers) * N.Element_Count (Kept)
                   * N.Element_Count (Narrow) * 2 - 1);
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
               First => 0, Last => Steps - 1,
               K_Base => 0,
               V_Base => Layers * Kept * Narrow,
               KV_Width => Narrow, V_Width => Narrow,
               Group_Size => Sharing,
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

      --  As Take, but with a matrix product submitted before each attention,
      --  which is what a layer does around it. A call timed on an idle
      --  device is not a call in a layer.
      procedure Busy
        (Heads   : Natural;
         Wide    : Natural;
         Steps   : Natural;
         Sharing : Natural := 1;
         Layers  : Natural := 1;
         Room    : Natural := 0)
      is
         use type N.Element_Count;
         use type Model_Runner.Bytes.Byte_Count;

         Groups : constant Natural := Heads / Sharing;
         Narrow : constant Natural := Groups * Wide;
         Span   : constant Natural := Heads * Wide;
         Kept   : constant Natural := (if Room = 0 then Steps else Room);

         type Values is access N.Real_Array;
         type Bytes_Access is access Model_Runner.Bytes.Byte_Array;

         Cache : constant Values :=
           new N.Real_Array
             (0 .. N.Element_Count (Layers) * N.Element_Count (Kept)
                   * N.Element_Count (Narrow) * 2 - 1);
         Asked : constant Values :=
           new N.Real_Array (0 .. N.Element_Count (Span) - 1);
         Got   : constant Values :=
           new N.Real_Array (0 .. N.Element_Count (Span) - 1);

         Rows : constant Natural := Span;
         Cols : constant Natural := Span;

         Weights : constant Bytes_Access :=
           new Model_Runner.Bytes.Byte_Array
             (1 .. Model_Runner.Bytes.Byte_Count (Rows * Cols * 4));
         Product : constant Values :=
           new N.Real_Array (0 .. N.Element_Count (Rows) - 1);

         Started : Ada.Calendar.Time;
         Spent   : Duration;
         Ok      : Boolean;
         Halted  : Boolean;
      begin
         Cache.all := [others => 0.125];
         Asked.all := [others => 0.25];
         Weights.all := [others => 0];

         Products.Reserve (Engine, Cache.all'Length, Ok);
         if not Ok then
            return;
         end if;
         Products.Put_Cache (Engine, 0, Cache.all, Ok);
         if not Ok then
            return;
         end if;

         --  The product on its own first, so that what the attention adds
         --  beside it can be told from what the product costs. A pair timed
         --  without this says only that a matrix of four million weights is
         --  not free.
         Started := Ada.Calendar.Clock;
         for Round in 1 .. Rounds loop
            Products.Multiply
              (Engine, Weights.all, 0, Products.Values_F32, Rows, Cols,
               Asked.all, 1, Product.all, Ok, Halted);
         end loop;

         Ada.Text_IO.Put_Line
           ("    the product alone:"
            & Duration'Image ((Ada.Calendar.Clock - Started) / Rounds)
            & " s");

         Started := Ada.Calendar.Clock;

         for Round in 1 .. Rounds loop
            Products.Multiply
              (Engine, Weights.all, 0, Products.Values_F32, Rows, Cols,
               Asked.all, 1, Product.all, Ok, Halted);

            Products.Attend_Resident
              (Engine, Asked.all,
               Heads => Heads, Head_Size => Wide, Value_Size => Wide,
               Group_Size => Sharing, First => 0, Last => Steps - 1,
               K_Base => 0, V_Base => Layers * Kept * Narrow,
               KV_Width => Narrow, V_Width => Narrow,
               Scale => 0.125, Cap => 0.0, Target => Got.all, Ok => Ok);
            exit when not Ok;
         end loop;

         Spent := (Ada.Calendar.Clock - Started) / Rounds;

         Ada.Text_IO.Put_Line
           ("    a product and an attention together:"
            & Duration'Image (Spent) & " s a pair");

         --  And the same attention reading a different layer's region every
         --  call, as a token does: twenty-two of them, ninety megabytes
         --  apart end to end. Every call above read the first layer's keys,
         --  which after the first is a region already warm.
         Started := Ada.Calendar.Clock;

         for Round in 1 .. Rounds loop
            declare
               Layer : constant Natural := (Round - 1) mod Layers;
            begin
               Products.Attend_Resident
                 (Engine, Asked.all,
                  Heads => Heads, Head_Size => Wide, Value_Size => Wide,
                  Group_Size => Sharing, First => 0, Last => Steps - 1,
                  K_Base => Layer * Kept * Narrow,
                  V_Base => Layers * Kept * Narrow
                            + Layer * Kept * Narrow,
                  KV_Width => Narrow, V_Width => Narrow,
                  Scale => 0.125, Cap => 0.0, Target => Got.all, Ok => Ok);
               exit when not Ok;
            end;
         end loop;

         Ada.Text_IO.Put_Line
           ("    attention walking every layer's region:"
            & Duration'Image ((Ada.Calendar.Clock - Started) / Rounds)
            & " s a call");
      end Busy;
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

      --  And what the engine actually asks for: thirty-two query heads
      --  sharing four groups of keys, across twenty-two layers of a context
      --  two thousand deep, attending to five hundred of them.
      Ada.Text_IO.Put_Line ("  as the engine asks it:");
      Take (32, 64, 512, Sharing => 8, Layers => 22, Room => 2048);

      --  The same, with a matrix product submitted between each attention,
      --  as a layer does. A call timed on an idle device is not a call in a
      --  layer: the layer submits four products around it, and a submission
      --  that queues behind them waits for them.
      Ada.Text_IO.Put_Line ("  with a layer's other work between:");
      Busy (32, 64, 512, Sharing => 8, Layers => 22, Room => 2048);

      Products.Close (Engine);
      Devices.Close (Opened);
      Devices.Close (Held);
   end Report;

end Device_Bench;
