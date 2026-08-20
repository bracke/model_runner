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

         --  A layer's shape: four products around one attention, and the
         --  same four without it. The difference is what the attention adds
         --  where it is actually called, which is the question a pair of
         --  one product could only hint at -- and it read 0.703 ms one run
         --  and 1.810 ms the next, so this says both figures every time
         --  rather than one of them.
         for Attempt in 1 .. 3 loop
            declare
               Bare : Duration;
               Both : Duration;

               --  What a layer submits: the queries, keys and values as one,
               --  the attention output, the gate and up as one, and the
               --  projection down. Four, whatever the grouping does to them.
               Sends : constant := 4;
            begin
               Started := Ada.Calendar.Clock;
               for Round in 1 .. Rounds loop
                  for Each in 1 .. Sends loop
                     Products.Multiply
                       (Engine, Weights.all, 0, Products.Values_F32,
                        Rows, Cols, Asked.all, 1, Product.all, Ok, Halted);
                  end loop;
               end loop;
               Bare := (Ada.Calendar.Clock - Started) / Rounds;

               Started := Ada.Calendar.Clock;
               for Round in 1 .. Rounds loop
                  for Each in 1 .. Sends loop
                     Products.Multiply
                       (Engine, Weights.all, 0, Products.Values_F32,
                        Rows, Cols, Asked.all, 1, Product.all, Ok, Halted);
                  end loop;

                  Products.Attend_Resident
                    (Engine, Asked.all,
                     Heads => Heads, Head_Size => Wide, Value_Size => Wide,
                     Group_Size => Sharing, First => 0, Last => Steps - 1,
                     K_Base => 0, V_Base => Layers * Kept * Narrow,
                     KV_Width => Narrow, V_Width => Narrow,
                     Scale => 0.125, Cap => 0.0, Target => Got.all,
                     Ok => Ok);
               end loop;
               Both := (Ada.Calendar.Clock - Started) / Rounds;

               Ada.Text_IO.Put_Line
                 ("    four products" & Duration'Image (Bare)
                  & " s, with an attention" & Duration'Image (Both)
                  & " s, the attention" & Duration'Image (Both - Bare)
                  & " s");
            end;
         end loop;

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

      --  Whether reserving a cache costs the weights their place.
      --
      --  The engine keeps a model's matrices on the device and gives the
      --  least-wanted one back when the next will not fit a budget that is a
      --  fixed share of the heap, decided when the device opened. A cache
      --  reserved afterwards takes device memory that budget knows nothing
      --  about. If that is what makes a wired run slow, then cycling
      --  products through more matrices than the budget holds gets slower
      --  once a cache is reserved, and the count given back rises.
      procedure Squeeze (Wide : Natural; Many : Natural; Cache : Natural) is
         use type N.Element_Count;
         use type Model_Runner.Bytes.Byte_Count;

         type Values is access N.Real_Array;
         type Bytes_Access is access Model_Runner.Bytes.Byte_Array;

         Weights : constant Bytes_Access :=
           new Model_Runner.Bytes.Byte_Array
             (1 .. Model_Runner.Bytes.Byte_Count (Many)
                   * Model_Runner.Bytes.Byte_Count (Wide * Wide * 4));

         Asked : constant Values :=
           new N.Real_Array (0 .. N.Element_Count (Wide) - 1);
         Got   : constant Values :=
           new N.Real_Array (0 .. N.Element_Count (Wide) - 1);

         Room : Values;

         Started : Ada.Calendar.Time;
         Ok      : Boolean;
         Halted  : Boolean;

         Before, After : Natural;
      begin
         Weights.all := [others => 0];
         Asked.all := [others => 0.25];

         if Cache > 0 then
            Room := new N.Real_Array (0 .. N.Element_Count (Cache) - 1);
            Room.all := [others => 0.0];
            Products.Reserve (Engine, Room.all'Length, Ok);
            if not Ok then
               Ada.Text_IO.Put_Line ("    no room for the cache");
               return;
            end if;
         end if;

         --  Once through to settle what is kept, then the timed pass.
         --  Each with a key of its own, which is what asks the device to
         --  keep it. Without one nothing is kept and the question is not
         --  being put at all -- the first pass at this measured that and
         --  reported nothing kept, which was the test failing to ask rather
         --  than the device declining.
         for Round in 1 .. Many loop
            declare
               At_Byte : constant Model_Runner.Bytes.Byte_Count :=
                 Model_Runner.Bytes.Byte_Count ((Round - 1) * Wide * Wide * 4);
            begin
               Products.Multiply
                 (Engine, Weights.all, At_Byte,
                  Products.Values_F32, Wide, Wide, Asked.all, 1, Got.all,
                  Ok, Halted,
                  Key => Weights.all (Weights.all'First + At_Byte)'Address);
            end;
         end loop;

         Before := Products.Given_Back (Engine);
         Started := Ada.Calendar.Clock;

         for Pass in 1 .. 3 loop
            for Round in 1 .. Many loop
               declare
                  At_Byte : constant Model_Runner.Bytes.Byte_Count :=
                    Model_Runner.Bytes.Byte_Count
                      ((Round - 1) * Wide * Wide * 4);
               begin
                  Products.Multiply
                    (Engine, Weights.all, At_Byte,
                     Products.Values_F32, Wide, Wide, Asked.all, 1, Got.all,
                     Ok, Halted,
                     Key =>
                       Weights.all (Weights.all'First + At_Byte)'Address);
               end;
            end loop;
         end loop;

         After := Products.Given_Back (Engine);

         Ada.Text_IO.Put_Line
           ("    cache" & Natural'Image (Cache / 262_144) & " MiB:"
            & Duration'Image ((Ada.Calendar.Clock - Started) / (3 * Many))
            & " s a product," & Natural'Image (After - Before)
            & " given back," & Natural'Image (Products.Resident (Engine))
            & " kept");
      end Squeeze;
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

      --  Twenty matrices of a thousand square, which is eighty megabytes of
      --  weights, first with no cache and then with eighty-eight megabytes
      --  of one.
      Ada.Text_IO.Put_Line ("  weights against a reserved cache:");
      Squeeze (1024, 20, 0);
      Squeeze (1024, 20, 23_068_672);

      Products.Close (Engine);
      Devices.Close (Opened);
      Devices.Close (Held);
   end Report;

end Device_Bench;
