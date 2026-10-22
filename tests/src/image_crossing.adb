with Ada.Calendar;
with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Text_IO;
with Interfaces;

with Model_Runner.Backend;
with Model_Runner.Backend.CPU;
with Model_Runner.Backend.Device;
with Model_Runner.Byte_Sources.Files;
with Model_Runner.Bytes;
with Model_Runner.Errors;
with Model_Runner.GGUF.Containers;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Llama;
with Model_Runner.Numerics;
with Model_Runner.Philox;
with Model_Runner.Images;
with Model_Runner.Platform;
with Model_Runner.Qwen_Image;
with Model_Runner.Qwen_Image.Decoder;
with Model_Runner.Qwen_Image.Prompts;
with Model_Runner.Tensors;
with Model_Runner.Vision;
with Ada.Unchecked_Deallocation;

package body Image_Crossing is

   package E renames Model_Runner.Errors;
   package N renames Model_Runner.Numerics;
   package Q renames Model_Runner.Qwen_Image;
   package Dec renames Model_Runner.Qwen_Image.Decoder;
   package Tk renames Model_Runner.Tensors;
   package U renames Ada.Strings.Unbounded;

   use type Ada.Streams.Stream_Element_Offset;
   use type Model_Runner.Bytes.Byte_Count;
   use type N.Element_Count;
   use type N.Real;
   use type N.Wide_Real;
   use type Tk.Real_Array_Access;
   use type Model_Runner.Qwen_Image.Prompts.Slots_Access;

   --  The files by their published names, as `model_runner image` finds
   --  them.
   Encoder_Name : constant String := "Qwen3-VL-8B-Instruct-Q8_0.gguf";
   VAE_Name     : constant String := "qwen_image_2.1_vae_bf16.safetensors";
   Projector_Name : constant String := "mmproj-Qwen3VL-8B-Instruct-F16.gguf";

   procedure Free is new Ada.Unchecked_Deallocation
     (Model_Runner.Qwen_Image.Slot_List, Model_Runner.Qwen_Image.Prompts.Slots_Access);

   type Wide_Access is access N.Wide_Real_Array;

   --  One recorded run of values: which row or step, every Stride-th value
   --  from the first.
   type Recorded is record
      Which  : Natural := 0;
      Stride : Positive := 1;
      Values : Wide_Access;
   end record;

   type Recorded_List is array (Positive range <>) of Recorded;

   function Run (Given : Settings) return Natural is
      File_Name : U.Unbounded_String;
      Prompt    : U.Unbounded_String;
      Width, Height, Seed, Steps, Kept_Rows : Natural := 0;
      Row_Tolerance : N.Wide_Real := 0.08;
      Cosine_Floor  : N.Wide_Real := 0.9999;
      Referenced_Floor : N.Wide_Real := 0.9999;
      Rows_Seen     : Recorded_List (1 .. 8);
      Speeds_Seen   : Recorded_List (1 .. 2);
      --  With guidance: the negative's velocities, the negative prompt
      --  and how far each step leans; and the levels where the run named
      --  its own.
      Aways_Seen    : Recorded_List (1 .. 2);
      Away_Count    : Natural := 0;
      Negative      : U.Unbounded_String;
      Guidance      : N.Real := 1.0;
      Named_Levels  : Wide_Access;
      --  A picture drawn from another: its file beside the expectation, how
      --  much of it is drawn anew, and the encoder's mean of it recorded.
      Init_Name     : U.Unbounded_String;
      Strength      : N.Real := 1.0;
      Encoded_Seen  : Recorded;
      Init_Latent   : Tk.Real_Array_Access;
      --  An edit: the pictures beside it, by their files beside the
      --  expectation, and the encoder's mean of the first recorded.
      Reference_Names : array (1 .. 4) of U.Unbounded_String;
      Reference_Count : Natural := 0;
      Referenced_Seen : Recorded;
      Row_Count, Speed_Count : Natural := 0;
      Failed : Boolean := False;

      procedure Fail (Why : String) is
      begin
         Failed := True;
         Ada.Text_IO.Put_Line ("image: expectation not met: " & Why);
      end Fail;

      --  The words of a line from a position on: the next one, and where it
      --  ends.
      procedure Next_Word (Line : String; From : in out Natural; First, Last : out Natural) is
      begin
         while From <= Line'Last and then Line (From) = ' ' loop
            From := From + 1;
         end loop;
         First := From;
         while From <= Line'Last and then Line (From) /= ' ' loop
            From := From + 1;
         end loop;
         Last := From - 1;
      end Next_Word;

      --  "KEY WHICH stride S v v v ...", read into a recording.
      function Read_Run (Line : String; From : Natural) return Recorded is
         At_Word : Natural := From;
         First, Last : Natural;
         Result : Recorded;
         Count : Natural := 0;
      begin
         Next_Word (Line, At_Word, First, Last);
         Result.Which := Natural'Value (Line (First .. Last));
         Next_Word (Line, At_Word, First, Last);
         Next_Word (Line, At_Word, First, Last);
         Result.Stride := Positive'Value (Line (First .. Last));
         declare
            Probe : Natural := At_Word;
         begin
            loop
               Next_Word (Line, Probe, First, Last);
               exit when First > Last;
               Count := Count + 1;
            end loop;
         end;
         Result.Values := new N.Wide_Real_Array (0 .. N.Element_Count (Count) - 1);
         for Index in Result.Values'Range loop
            Next_Word (Line, At_Word, First, Last);
            Result.Values (Index) := N.Wide_Real'Value (Line (First .. Last));
         end loop;
         return Result;
      end Read_Run;

      --  How far Got is from a recording, every Stride-th value from
      --  Start: the distance over the recording's norm, and the cosine.
      procedure Against
        (Got : N.Real_Array; Start : N.Element_Count; Seen : Recorded; Apart, Cosine : out N.Wide_Real)
      is
         Dot, Norm_Got, Norm_Seen, Distance : N.Wide_Real := 0.0;
      begin
         for Index in Seen.Values'Range loop
            declare
               Mine : constant N.Wide_Real :=
                 N.Wide_Real (Got (Got'First + Start + Index * N.Element_Count (Seen.Stride)));
               Theirs : constant N.Wide_Real := Seen.Values (Index);
            begin
               Dot := Dot + Mine * Theirs;
               Norm_Got := Norm_Got + Mine * Mine;
               Norm_Seen := Norm_Seen + Theirs * Theirs;
               Distance := Distance + (Mine - Theirs) ** 2;
            end;
         end loop;
         Apart := N.Sqrt (Distance) / N.Sqrt (Norm_Seen);
         Cosine := Dot / (N.Sqrt (Norm_Got) * N.Sqrt (Norm_Seen));
      end Against;

      function Path_Of (Given_Path : U.Unbounded_String; Published : String) return String
      is (Model_Runner.Platform.Resolve_Model_Path
            (if U.Length (Given_Path) = 0 then Published else U.To_String (Given_Path)));

      Status : E.Error_Info;
   begin
      if not Ada.Directories.Exists (U.To_String (Given.Expect)) then
         Ada.Text_IO.Put_Line ("image: no expectation at " & U.To_String (Given.Expect));
         return 1;
      end if;
      declare
         File : Ada.Text_IO.File_Type;
      begin
         Ada.Text_IO.Open (File, Ada.Text_IO.In_File, U.To_String (Given.Expect));
         while not Ada.Text_IO.End_Of_File (File) loop
            declare
               Line : constant String := Ada.Text_IO.Get_Line (File);
               At_Word : Natural := Line'First;
               First, Last : Natural;
            begin
               Next_Word (Line, At_Word, First, Last);
               declare
                  Key  : constant String := Line (First .. Last);
                  Rest : constant String :=
                    (if At_Word < Line'Last then Line (At_Word + 1 .. Line'Last) else "");
               begin
                  if Key = "file" then
                     File_Name := U.To_Unbounded_String (Rest);
                  elsif Key = "prompt" then
                     Prompt := U.To_Unbounded_String (Rest);
                  elsif Key = "size" then
                     Next_Word (Line, At_Word, First, Last);
                     Width := Natural'Value (Line (First .. Last));
                     Next_Word (Line, At_Word, First, Last);
                     Height := Natural'Value (Line (First .. Last));
                  elsif Key = "seed" then
                     Seed := Natural'Value (Rest);
                  elsif Key = "steps" then
                     Steps := Natural'Value (Rest);
                  elsif Key = "rows" then
                     Kept_Rows := Natural'Value (Rest);
                  elsif Key = "row-tolerance" then
                     Row_Tolerance := N.Wide_Real'Value (Rest);
                  elsif Key = "velocity-cosine" then
                     Cosine_Floor := N.Wide_Real'Value (Rest);
                  elsif Key = "row" and then Row_Count < Rows_Seen'Last then
                     Row_Count := Row_Count + 1;
                     Rows_Seen (Row_Count) := Read_Run (Line, At_Word);
                  elsif Key = "negative" then
                     Negative := U.To_Unbounded_String (Rest);
                  elsif Key = "cfg" then
                     Guidance := N.Real'Value (Rest);
                  elsif Key = "sigmas" then
                     declare
                        Read : constant Recorded := Read_Run ("x 0 stride 1 " & Rest, 2);
                     begin
                        Named_Levels := Read.Values;
                     end;
                  elsif Key = "init" then
                     Init_Name := U.To_Unbounded_String (Rest);
                  elsif Key = "strength" then
                     Strength := N.Real'Value (Rest);
                  elsif Key = "reference" and then Reference_Count < Reference_Names'Last then
                     Reference_Count := Reference_Count + 1;
                     Reference_Names (Reference_Count) := U.To_Unbounded_String (Rest);
                  elsif Key = "referenced-cosine" then
                     Referenced_Floor := N.Wide_Real'Value (Rest);
                  elsif Key = "referenced" then
                     Referenced_Seen := Read_Run ("x 0 " & Rest, 2);
                  elsif Key = "encoded" then
                     Encoded_Seen := Read_Run ("x 0 " & Rest, 2);
                  elsif Key = "away" and then Away_Count < Aways_Seen'Last then
                     Away_Count := Away_Count + 1;
                     Aways_Seen (Away_Count) := Read_Run (Line, At_Word);
                  elsif Key = "velocity" and then Speed_Count < Speeds_Seen'Last then
                     Speed_Count := Speed_Count + 1;
                     Speeds_Seen (Speed_Count) := Read_Run (Line, At_Word);
                  end if;
               end;
            end;
         end loop;
         Ada.Text_IO.Close (File);
      end;
      if U.Length (Prompt) = 0 or else Width = 0 or else Height = 0 or else Steps = 0 or else Row_Count = 0
        or else Speed_Count < 2 or else Width mod Dec.Upscale /= 0 or else Height mod Dec.Upscale /= 0
      then
         Ada.Text_IO.Put_Line ("image: the expectation lacks its prompt, size, steps, rows or velocities");
         return 1;
      end if;

      declare
         Encoder_Path  : constant String := Path_Of (Given.Text_Encoder, Encoder_Name);
         Denoiser_Path : constant String := Path_Of (Given.Model, U.To_String (File_Name));
         VAE_Path      : constant String := Path_Of (Given.VAE, VAE_Name);
         Latent_Rows    : constant Positive := Height / Dec.Upscale;
         Latent_Columns : constant Positive := Width / Dec.Upscale;
         Team : aliased Model_Runner.Backend.CPU.Pool
           (Model_Runner.Backend.CPU.Worker_Count
              (Natural'Max (1, Natural'Min (Model_Runner.Backend.CPU.Max_Workers,
                                            Model_Runner.Backend.CPU.Default_Workers
                                              (Model_Runner.Platform.Core_Count)))));
         Pool : constant Model_Runner.Backend.CPU.Pool_Reference := Team'Unchecked_Access;
         Text : Tk.Real_Array_Access;
         Text_Rows : Natural := 0;
         Away_Text : Tk.Real_Array_Access;
         Away_Rows : Natural := 0;
         Ready : Boolean := False;
         --  An edit's pictures at their sizes, their latents, and the slots
         --  of the prompt's rows and the negative's.
         Sized   : Q.Prompts.Picture_List (1 .. Reference_Count);
         Latents : array (1 .. Reference_Count) of Tk.Real_Array_Access;
         Slots, Away_Slots : Q.Prompts.Slots_Access;

         function Pictured return Q.Reference_List is
            Result : Q.Reference_List (1 .. Reference_Count);
         begin
            for Index in Result'Range loop
               Result (Index) := (Latent => Latents (Index), Rows => Sized (Index).Height / Dec.Upscale,
                                  Columns => Sized (Index).Width / Dec.Upscale);
            end loop;
            return Result;
         end Pictured;

         procedure Open_Device is
         begin
            if Given.On_Device then
               Model_Runner.Backend.Device.Open (Ready);
               if not Ready then
                  Ada.Text_IO.Put_Line ("image: no device opened; on the processor");
               end if;
            end if;
         end Open_Device;
      begin
         if not Ada.Directories.Exists (Encoder_Path) or else not Ada.Directories.Exists (Denoiser_Path) then
            Ada.Text_IO.Put_Line
              ("image: skipped (no "
               & (if Ada.Directories.Exists (Encoder_Path) then Denoiser_Path else Encoder_Path) & ")");
            return 0;
         end if;
         Model_Runner.Backend.CPU.Use_Integer_Activations (Model_Runner.Backend.CPU.Every_Role);
         Model_Runner.Backend.CPU.Open (Team);

         --  The prompt's rows, the encoder let go after.
         Open_Device;
         declare
            Source    : Model_Runner.Byte_Sources.Files.File_Source;
            Container : Model_Runner.GGUF.Containers.Container;
            Encoder   : Model_Runner.Llama.Model;
            Ignored   : E.Error_Info;
         begin
            Model_Runner.Byte_Sources.Files.Open (Source, Encoder_Path, Status => Status);
            if E.Is_Ok (Status) then
               Model_Runner.GGUF.Containers.Reader.Parse (Container, Source, Status => Status);
            end if;
            if E.Is_Ok (Status) then
               Model_Runner.Llama.Prepare
                 (Encoder, Container, Source,
                  Backend => (if Ready then Model_Runner.Backend.Backend_Device else Model_Runner.Backend.Backend_CPU),
                  Repack  => (if Ready then Model_Runner.Llama.No_Repack else Model_Runner.Llama.To_Rows),
                  Threads => Model_Runner.Platform.Core_Count, Status => Status,
                  Context => Q.Prompts.Max_Tokens);
            end if;
            --  An edit's pictures, read and sized as the reference sizes
            --  them, then the prompt read beside them.
            for Index in 1 .. Reference_Count loop
               exit when E.Is_Error (Status);
               declare
                  Raster : Model_Runner.Images.Raster;
                  Wide, Tall : Positive;
               begin
                  Model_Runner.Images.Load
                    (Ada.Directories.Containing_Directory (U.To_String (Given.Expect)) & "/"
                     & U.To_String (Reference_Names (Index)), Raster, Status);
                  if E.Is_Ok (Status) then
                     Q.Reference_Size (Width, Height, Raster.Width, Raster.Height, Wide, Tall);
                     Model_Runner.Images.Nearest (Raster, Wide, Tall, Sized (Index));
                     Ada.Text_IO.Put_Line ("reference" & Index'Image & " at" & Wide'Image & " by" & Tall'Image);
                  end if;
                  Model_Runner.Images.Free (Raster);
               end;
            end loop;
            if E.Is_Ok (Status) and then Reference_Count > 0 then
               declare
                  Eyes : Model_Runner.Vision.Encoder;
               begin
                  Model_Runner.Vision.Open (Eyes, Path_Of (Given.Projector, Projector_Name), Status);
                  if E.Is_Ok (Status) then
                     Q.Prompts.Encode_With_Pictures
                       (Encoder, Eyes, U.To_String (Prompt), Sized, Text, Text_Rows, Slots, Status, Pool);
                  end if;
                  if E.Is_Ok (Status) and then Guidance /= 1.0 then
                     Q.Prompts.Encode_With_Pictures
                       (Encoder, Eyes, U.To_String (Negative), Sized, Away_Text, Away_Rows, Away_Slots, Status,
                        Pool);
                  end if;
                  Model_Runner.Vision.Close (Eyes);
               end;
            elsif E.Is_Ok (Status) then
               Q.Prompts.Encode (Encoder, U.To_String (Prompt), Text, Text_Rows, Status, Pool);
               if E.Is_Ok (Status) and then Guidance /= 1.0 then
                  Q.Prompts.Encode (Encoder, U.To_String (Negative), Away_Text, Away_Rows, Status, Pool);
               end if;
            end if;
            Model_Runner.Llama.Close (Encoder, Ignored);
            Model_Runner.GGUF.Containers.Close (Container);
            Model_Runner.Byte_Sources.Files.Close (Source);
         end;
         if Ready then
            Model_Runner.Backend.Device.Close;
         end if;
         if E.Is_Error (Status) then
            Ada.Text_IO.Put_Line ("image: the encoder failed: " & E.Error_Code'Image (Status.Code));
            Model_Runner.Backend.CPU.Close (Team);
            return 1;
         end if;

         Ada.Text_IO.Put_Line ("rows:" & Text_Rows'Image);
         if Text_Rows /= Kept_Rows then
            Fail ("the rows are" & Text_Rows'Image & ", not" & Kept_Rows'Image);
         else
            declare
               Context : constant N.Element_Count := Text'Length / N.Element_Count (Text_Rows);
               Apart, Cosine : N.Wide_Real;
            begin
               for Index in 1 .. Row_Count loop
                  Against (Text.all, N.Element_Count (Rows_Seen (Index).Which) * Context, Rows_Seen (Index), Apart,
                           Cosine);
                  Ada.Text_IO.Put_Line
                    ("row" & Rows_Seen (Index).Which'Image & " apart by" & Apart'Image & " of its norm, cosine"
                     & Cosine'Image);
                  if Apart > Row_Tolerance then
                     Fail ("row" & Rows_Seen (Index).Which'Image & " is further than the tolerance");
                  end if;
               end loop;
            end;
         end if;

         --  An edit's pictures through the VAE's encoder, the first's mean
         --  against the reference's.
         for Index in 1 .. Reference_Count loop
            exit when E.Is_Error (Status);
            declare
               Tall   : constant Positive := Sized (Index).Height;
               Wide   : constant Positive := Sized (Index).Width;
               Planes : Tk.Real_Array_Access;
               VAE    : Dec.Picture_Decoder;
               Cells  : constant N.Element_Count := N.Element_Count ((Tall / Dec.Upscale) * (Wide / Dec.Upscale));
               Apart, Cosine : N.Wide_Real;
            begin
               Tk.Allocate (N.Element_Count (Dec.Picture_Channels * Tall * Wide), Planes);
               Dec.From_Raster (Sized (Index), Tall, Wide, Planes.all);
               Dec.Open (VAE, VAE_Path, Status, Encoder => True);
               if E.Is_Ok (Status) then
                  Tk.Allocate (N.Element_Count (Dec.Latent_Channels) * Cells, Latents (Index));
                  Dec.Encode (VAE, Planes.all, Tall, Wide, Pool, Latents (Index).all, Status);
               end if;
               Dec.Close (VAE);
               Tk.Free (Planes);
               if E.Is_Error (Status) then
                  Fail ("a reference was not encoded: " & E.Error_Code'Image (Status.Code));
               elsif Index = 1 and then Referenced_Seen.Values /= null then
                  declare
                     Mean : N.Real_Array (Latents (Index)'Range);
                  begin
                     for I in Mean'Range loop
                        Mean (I) := Latents (Index) (I) * Dec.Latent_Deviations (Natural (I / Cells))
                          + Dec.Latent_Means (Natural (I / Cells));
                     end loop;
                     Against (Mean, 0, Referenced_Seen, Apart, Cosine);
                     Ada.Text_IO.Put_Line ("referenced: cosine" & Cosine'Image & ", apart by" & Apart'Image);
                     if Cosine < Referenced_Floor then
                        Fail ("the reference's latent is below the cosine");
                     end if;
                  end;
               end if;
            end;
         end loop;

         --  A picture drawn from another: the picture read and encoded, its
         --  mean against the reference's.
         if U.Length (Init_Name) > 0 then
            declare
               Path   : constant String :=
                 Ada.Directories.Containing_Directory (U.To_String (Given.Expect)) & "/" & U.To_String (Init_Name);
               Raster : Model_Runner.Images.Raster;
               Planes : Tk.Real_Array_Access;
               VAE    : Dec.Picture_Decoder;
               Cells  : constant N.Element_Count := N.Element_Count (Latent_Rows * Latent_Columns);
               Apart, Cosine : N.Wide_Real;
            begin
               Model_Runner.Images.Load (Path, Raster, Status);
               if E.Is_Ok (Status) then
                  Tk.Allocate (N.Element_Count (Dec.Picture_Channels * Width * Height), Planes);
                  Dec.From_Raster (Raster, Height, Width, Planes.all);
                  Dec.Open (VAE, VAE_Path, Status, Encoder => True);
               end if;
               if E.Is_Ok (Status) then
                  Tk.Allocate (N.Element_Count (Dec.Latent_Channels) * Cells, Init_Latent);
                  Dec.Encode (VAE, Planes.all, Height, Width, Pool, Init_Latent.all, Status);
               end if;
               Dec.Close (VAE);
               Model_Runner.Images.Free (Raster);
               Tk.Free (Planes);
               if E.Is_Error (Status) then
                  Fail ("the picture was not encoded: " & E.Error_Code'Image (Status.Code));
               elsif Encoded_Seen.Values /= null then
                  declare
                     Mean : N.Real_Array (Init_Latent'Range);
                  begin
                     for I in Mean'Range loop
                        Mean (I) := Init_Latent (I) * Dec.Latent_Deviations (Natural (I / Cells))
                          + Dec.Latent_Means (Natural (I / Cells));
                     end loop;
                     Against (Mean, 0, Encoded_Seen, Apart, Cosine);
                     Ada.Text_IO.Put_Line ("encoded: cosine" & Cosine'Image & ", apart by" & Apart'Image);
                     if Cosine < Cosine_Floor then
                        Fail ("the encoded picture is below the cosine");
                     end if;
                  end;
               end if;
            end;
         end if;

         --  The first two steps, the prompt's rows kept from the first.
         Open_Device;
         declare
            Model  : Q.Denoiser;
            Prefix, Away_Prefix : Q.Prefix_Cache;
         begin
            Q.Open (Model, Denoiser_Path, Status, Panels => not Ready);
            if E.Is_Ok (Status) then
               declare
                  Image  : constant N.Element_Count := N.Element_Count (Latent_Rows * Latent_Columns);
                  Planes : constant N.Element_Count := N.Element_Count (Q.Config (Model).Out_Channels) * Image;
                  All_Levels : constant N.Real_Array :=
                    (if Named_Levels = null then Q.Sigmas (Steps, Latent_Rows * Latent_Columns)
                     else [for I in Named_Levels'Range => N.Real (Named_Levels (I))]);
                  Start  : constant N.Element_Count :=
                    (if Init_Latent = null then 0 else N.Element_Count (Q.First_Level (Steps, Strength)));
                  Levels : constant N.Real_Array := All_Levels (All_Levels'First + Start .. All_Levels'Last);
                  Latent, Speed, Away_Speed : N.Real_Array (0 .. Planes - 1);
                  Noise  : Model_Runner.Philox.Generator := Model_Runner.Philox.Seeded (Interfaces.Unsigned_64 (Seed));
                  Apart, Cosine : N.Wide_Real;
               begin
                  Model_Runner.Philox.Draw (Noise, Latent);
                  if Init_Latent /= null then
                     for I in Latent'Range loop
                        Latent (I) := Init_Latent (I) * (1.0 - Levels (Levels'First))
                          + Latent (I) * Levels (Levels'First);
                     end loop;
                  end if;
                  for Step in 1 .. 2 loop
                     declare
                        Sigma : constant N.Real := Levels (Levels'First + N.Element_Count (Step) - 1);
                        Next  : constant N.Real := Levels (Levels'First + N.Element_Count (Step));
                     begin
                        Q.Velocity (Model, Latent, Latent_Rows, Latent_Columns, Sigma * 1000.0, Text.all, Text_Rows,
                                    Pool, Speed, Status, Prefix, Pictured,
                                    (if Slots = null then Q.No_Slots else Slots.all));
                        exit when E.Is_Error (Status);
                        for Seen of Speeds_Seen loop
                           if Seen.Which = Step then
                              Against (Speed, 0, Seen, Apart, Cosine);
                              Ada.Text_IO.Put_Line
                                ("velocity" & Step'Image & ": cosine" & Cosine'Image & ", apart by" & Apart'Image);
                              if Cosine < Cosine_Floor then
                                 Fail ("the velocity at step" & Step'Image & " is below the cosine");
                              end if;
                           end if;
                        end loop;
                        --  And the negative's, where guidance leans from it,
                        --  the step taken along the guided velocity.
                        if Guidance /= 1.0 then
                           Q.Velocity (Model, Latent, Latent_Rows, Latent_Columns, Sigma * 1000.0, Away_Text.all,
                                       Away_Rows, Pool, Away_Speed, Status, Away_Prefix, Pictured,
                                       (if Away_Slots = null then Q.No_Slots else Away_Slots.all));
                           exit when E.Is_Error (Status);
                           for Seen of Aways_Seen (1 .. Away_Count) loop
                              if Seen.Which = Step then
                                 Against (Away_Speed, 0, Seen, Apart, Cosine);
                                 Ada.Text_IO.Put_Line
                                   ("away" & Step'Image & ": cosine" & Cosine'Image & ", apart by" & Apart'Image);
                                 if Cosine < Cosine_Floor then
                                    Fail ("the negative's velocity at step" & Step'Image & " is below the cosine");
                                 end if;
                              end if;
                           end loop;
                           for I in Speed'Range loop
                              Speed (I) := Away_Speed (I) + Guidance * (Speed (I) - Away_Speed (I));
                           end loop;
                        end if;
                        for I in Latent'Range loop
                           Latent (I) := Latent (I) + (Next - Sigma) * Speed (I);
                        end loop;
                     end;
                  end loop;
               end;
            end if;
            Q.Forget (Prefix);
            Q.Forget (Away_Prefix);
            Q.Close (Model);
         end;
         Tk.Free (Text);
         Tk.Free (Away_Text);
         Tk.Free (Init_Latent);
         for Index in 1 .. Reference_Count loop
            Tk.Free (Latents (Index));
            Model_Runner.Images.Free (Sized (Index));
         end loop;
         Free (Slots);
         Free (Away_Slots);
         if E.Is_Error (Status) then
            Ada.Text_IO.Put_Line ("image: the denoiser failed: " & E.Error_Code'Image (Status.Code));
            if Ready then
               Model_Runner.Backend.Device.Close;
            end if;
            Model_Runner.Backend.CPU.Close (Team);
            return 1;
         end if;

         --  The reference's last latent decoded beside its picture.
         if U.Length (Given.Reference) > 0 then
            declare
               Latent_File  : constant String := U.To_String (Given.Reference) & "/latent40.f32";
               Picture_File : constant String := U.To_String (Given.Reference) & "/picture.pam";
               Pixels : constant N.Element_Count := N.Element_Count (Width * Height);
               Latent : N.Real_Array (0 .. Dec.Latent_Channels * N.Element_Count (Latent_Rows * Latent_Columns) - 1);
               Planes : Tk.Real_Array_Access;
               VAE    : Dec.Picture_Decoder;
            begin
               if not Ada.Directories.Exists (Latent_File) or else not Ada.Directories.Exists (Picture_File)
                 or else not Ada.Directories.Exists (VAE_Path)
               then
                  Ada.Text_IO.Put_Line ("image: the decoder skipped (no latent, picture or VAE)");
               else
                  declare
                     use Ada.Streams.Stream_IO;
                     Handle : File_Type;
                     Bytes  : Ada.Streams.Stream_Element_Array (1 .. Latent'Length * 4)
                       with Import, Address => Latent'Address;
                     Last   : Ada.Streams.Stream_Element_Offset;
                  begin
                     Open (Handle, In_File, Latent_File);
                     Read (Handle, Bytes, Last);
                     Close (Handle);
                  end;
                  Tk.Allocate (Pixels * Dec.Picture_Channels, Planes);
                  Dec.Open (VAE, VAE_Path, Status, Encoder => True);
                  if Given.Stripe_Bytes > 0 then
                     Dec.Set_Stripes (Given.Stripe_Bytes);
                  end if;
                  if E.Is_Ok (Status) then
                     Dec.Decode (VAE, Latent, Latent_Rows, Latent_Columns, Pool, Planes.all, Status);
                  end if;
                  --  The picture encoded back: near the latent it was
                  --  decoded from, as far as an autoencoder comes back.
                  if E.Is_Ok (Status) then
                     declare
                        Back  : Tk.Real_Array_Access;
                        Dot, Mine, Theirs : N.Wide_Real := 0.0;
                        Began : constant Ada.Calendar.Time := Ada.Calendar.Clock;
                        use type Ada.Calendar.Time;
                     begin
                        Tk.Allocate (Latent'Length, Back);
                        Dec.Encode (VAE, Planes.all, Height, Width, Pool, Back.all, Status);
                        if E.Is_Error (Status) then
                           Fail ("the encoder failed: " & E.Error_Code'Image (Status.Code));
                        else
                           for I in Latent'Range loop
                              Dot := Dot + N.Wide_Real (Latent (I)) * N.Wide_Real (Back (I - Latent'First));
                              Mine := Mine + N.Wide_Real (Back (I - Latent'First)) ** 2;
                              Theirs := Theirs + N.Wide_Real (Latent (I)) ** 2;
                           end loop;
                           Ada.Text_IO.Put_Line
                             ("encoded back: cosine" & N.Wide_Real'Image (Dot / N.Sqrt (Mine * Theirs)) & " in"
                              & Duration'Image (Ada.Calendar.Clock - Began) & " s");
                        end if;
                        Tk.Free (Back);
                     end;
                  end if;
                  Dec.Set_Stripes;
                  Dec.Close (VAE);
                  if E.Is_Error (Status) then
                     Fail ("the decoder failed: " & E.Error_Code'Image (Status.Code));
                  else
                     declare
                        Mine : constant Model_Runner.Bytes.Byte_Array := Dec.To_Pixels (Planes.all, Pixels);
                        use Ada.Streams.Stream_IO;
                        Handle : File_Type;
                        Size   : constant Ada.Streams.Stream_Element_Offset :=
                          Ada.Streams.Stream_Element_Offset (Ada.Directories.Size (Picture_File));
                        Whole  : Ada.Streams.Stream_Element_Array (1 .. Size);
                        Last   : Ada.Streams.Stream_Element_Offset;
                        Body_At : constant Ada.Streams.Stream_Element_Offset :=
                          Size - Ada.Streams.Stream_Element_Offset (Mine'Length) + 1;
                     begin
                        Open (Handle, In_File, Picture_File);
                        Read (Handle, Whole, Last);
                        Close (Handle);
                        if Body_At < 1 then
                           Fail ("the reference's picture is smaller than this one");
                        else
                           for Channel in 0 .. Dec.Picture_Channels - 1 loop
                              declare
                                 Sum : N.Wide_Real := 0.0;
                                 Ratio : N.Wide_Real;
                              begin
                                 for Pixel in 0 .. Pixels - 1 loop
                                    Sum := Sum
                                      + (N.Wide_Real (Mine (Mine'First + Model_Runner.Bytes.Byte_Count
                                                              (Pixel * Dec.Picture_Channels
                                                               + N.Element_Count (Channel))))
                                         - N.Wide_Real (Whole (Body_At + Ada.Streams.Stream_Element_Offset
                                                                  (Pixel * Dec.Picture_Channels
                                                                   + N.Element_Count (Channel))))) ** 2;
                                 end loop;
                                 Ratio := (if Sum = 0.0 then 999.0
                                           else 10.0 * N.Log (255.0 ** 2 / (Sum / N.Wide_Real (Pixels)))
                                                / N.Log (10.0));
                                 Ada.Text_IO.Put_Line
                                   ("picture, channel" & Channel'Image & ":" & Ratio'Image & " dB");
                                 if Ratio < 40.0 then
                                    Fail ("channel" & Channel'Image & " of the picture is under 40 dB");
                                 end if;
                              end;
                           end loop;
                        end if;
                     end;
                  end if;
                  Tk.Free (Planes);
               end if;
            end;
         end if;
         if Ready then
            Model_Runner.Backend.Device.Close;
         end if;
         Model_Runner.Backend.CPU.Close (Team);
      exception
         when others =>
            Model_Runner.Backend.CPU.Close (Team);
            raise;
      end;
      if Failed then
         return 1;
      end if;
      Ada.Text_IO.Put_Line ("image: the expectation is met");
      return 0;
   end Run;

end Image_Crossing;
