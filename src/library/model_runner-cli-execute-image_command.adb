with Ada.Calendar;
with Ada.Calendar.Formatting;
with Ada.Directories;
with Ada.Streams.Stream_IO;

with Hostkit.Metadata;

with Model_Runner.Backend.CPU;
with Model_Runner.Backend.Device;
with Model_Runner.Localization;
with Model_Runner.Platform;
with Model_Runner.PNG_Writer;
with Model_Runner.Qwen_Image;
with Model_Runner.Qwen_Image.Decoder;
with Model_Runner.Qwen_Image.Prompts;
with Model_Runner.Tensors;
with Model_Runner.CLI.Execute.Acquisition;

package body Model_Runner.CLI.Execute.Image_Command is

   use Model_Runner.CLI.Execute.Acquisition;
   use type N.Element_Count;
   use type Opt.Verbosity;

   package Q renames Model_Runner.Qwen_Image;
   package Dec renames Model_Runner.Qwen_Image.Decoder;
   package Tk renames Model_Runner.Tensors;

   use type Tk.Real_Array_Access;

   --  The files a picture is drawn with, by the names they are published
   --  under, found in the models directory unless named.
   Denoiser_Name     : constant String := "qwen-image-2.1-Q8_0.gguf";
   Turbo_Name        : constant String := "qwen-image-2.1-turbo-Q8_0.gguf";
   Text_Encoder_Name : constant String := "Qwen3-VL-8B-Instruct-Q8_0.gguf";
   VAE_Name          : constant String := "qwen_image_2.1_vae_bf16.safetensors";

   --  The seed a picture is drawn from where none is named: the reference's
   --  examples', so that a picture asked for twice is the same picture.
   Default_Seed : constant := 42;

   --------------
   -- Do_Image --
   --------------

   --  Draw a picture. The text encoder is read, used and let go before the
   --  denoiser is read -- the two together are 16 GB -- and the denoiser
   --  before the VAE.
   procedure Do_Image
     (Item   : Opt.Command;
      Screen : in out Pres.Console;
      Status : out Natural)
   is
      function Path_Of (Given : String; Published : String) return String
      is (Model_Runner.Platform.Resolve_Model_Path (if Given = "" then Published else Given));

      Rows    : constant Positive := Item.Image_Height / Dec.Upscale;
      Columns : constant Positive := Item.Image_Width / Dec.Upscale;
      Latent  : Tk.Real_Array_Access;
      Text    : Tk.Real_Array_Access;
      Text_Rows : Natural := 0;
      Away      : Tk.Real_Array_Access;
      Away_Rows : Natural := 0;
      Condition : E.Error_Info;

      procedure Fail (Reason : E.Error_Info) is
      begin
         Pres.Report (Screen, Reason);
         Status := E.Exit_Status (Reason);
         Tk.Free (Latent);
         Tk.Free (Text);
         Tk.Free (Away);
      end Fail;

      procedure Draw (Team : Model_Runner.Backend.CPU.Pool_Reference) is

         --  When the last step ended, or the steps began.
         Last_Step : Ada.Calendar.Time := Ada.Calendar.Clock;

         procedure Say_Step (Step : Positive; Steps : Positive) is
            use type Ada.Calendar.Time;
            Now   : constant Ada.Calendar.Time := Ada.Calendar.Clock;
            Tenth : constant Natural := Natural (10.0 * Float (Now - Last_Step));
            Took  : constant String := Natural'Image (Tenth / 10) & "." & Natural'Image (Tenth mod 10) (2);
         begin
            Last_Step := Now;
            if Item.Level /= Opt.Quiet then
               Pres.Put_Note
                 (Screen, "cli.image.step",
                  [Model_Runner.Localization.Named ("count", Step'Image (2 .. Step'Image'Last)),
                   Model_Runner.Localization.Named ("total", Steps'Image (2 .. Steps'Image'Last)),
                   Model_Runner.Localization.Named ("value", Took (2 .. Took'Last))]);
            end if;
         end Say_Step;
      begin
         --  The prompt's rows, from the cache where they are kept; else read
         --  by the encoder, let go after -- on the device where one opens
         --  and the encoder fits it, as run takes a model -- and kept.
         declare
            Asked     : Opt.Command := Item;
            Encoder   : constant String := Path_Of (T.To_String (Item.Text_Encoder_Path), Text_Encoder_Name);
            Leaning   : constant Boolean := N."/=" (Item.Image_Guidance, 1.0);
            Negative  : constant String := T.To_String (Item.Image_Negative);
         begin
            Asked.Model_Path := T.To_Bounded (Encoder);
            declare
               Chosen    : constant Opt.Command := Resolved_Backend (Asked, Screen);
               On_Device : constant Boolean :=
                 Model_Runner.Backend."=" (Chosen.Backend, Model_Runner.Backend.Backend_Device);

               --  Everything the rows depend on: the encoder file as it is,
               --  this build, the backend, the template and the prompt.
               function Key_Of (Prompt : String) return String is
                  Known : Boolean;
                  Stamp : constant String :=
                    (if Ada.Directories.Exists (Encoder) then Hostkit.Metadata.Change_Stamp (Encoder, Known) else "");
               begin
                  return "qwen-image-prompt|1|" & Model_Runner.Platform.Program_Stamp & "|" & Encoder & "|"
                    & (if Ada.Directories.Exists (Encoder)
                       then Ada.Directories.File_Size'Image (Ada.Directories.Size (Encoder)) & "|"
                            & Ada.Calendar.Formatting.Image
                                (Ada.Directories.Modification_Time (Encoder), Include_Time_Fraction => True)
                       else "")
                    & "|" & Stamp & "|" & (if On_Device then "device" else "cpu") & "|" & Q.Prompts.Template (Prompt);
               end Key_Of;
            begin
               if not Item.No_Cache then
                  Q.Prompts.Find_Kept (Key_Of (Item.Prompts (1).all), Text, Text_Rows);
                  if Leaning then
                     Q.Prompts.Find_Kept (Key_Of (Negative), Away, Away_Rows);
                  end if;
               end if;
               if Text = null or else (Leaning and then Away = null) then
                  declare
                     Source    : Shards.Shard_Set;
                     Container : Containers.Container;
                     Prepared  : L.Model;
                     Ignored   : E.Error_Info;
                     Ready     : Boolean := False;
                  begin
                     if On_Device then
                        Model_Runner.Backend.Device.Open
                          (Ready, Item.Device_Memory, Item.Device_Share, Patience => Item.Device_Patience,
                           Which => Item.Device_Index);
                     end if;
                     Load ((if Ready then Chosen else Asked), Screen, Source, Container, Prepared, True, null, null,
                           Condition);
                     if E.Is_Ok (Condition) and then Text = null then
                        Q.Prompts.Encode (Prepared, Item.Prompts (1).all, Text, Text_Rows, Condition);
                        if E.Is_Ok (Condition) and then not Item.No_Cache then
                           Q.Prompts.Keep (Key_Of (Item.Prompts (1).all), Text.all, Text_Rows);
                        end if;
                     end if;
                     --  What the picture is not to be, where guidance leans
                     --  from it: the empty prompt unless said, as the
                     --  reference reads it.
                     if E.Is_Ok (Condition) and then Leaning and then Away = null then
                        Q.Prompts.Encode (Prepared, Negative, Away, Away_Rows, Condition);
                        if E.Is_Ok (Condition) and then not Item.No_Cache then
                           Q.Prompts.Keep (Key_Of (Negative), Away.all, Away_Rows);
                        end if;
                     end if;
                     L.Close (Prepared, Ignored);
                     Containers.Close (Container);
                     Shards.Close (Source);
                     if Ready then
                        Model_Runner.Backend.Device.Close;
                     end if;
                  end;
               end if;
            end;
            if E.Is_Error (Condition) then
               Fail (Condition);
               return;
            end if;
         end;

         --  The latent, the denoiser let go after: on the device where one
         --  opens, its products and attention there; on the processor in
         --  panels otherwise.
         declare
            Model   : Q.Denoiser;
            On_Device : Boolean;
         begin
            Model_Runner.Backend.Device.Open
              (On_Device, Item.Device_Memory, Item.Device_Share, Patience => Item.Device_Patience,
               Which => Item.Device_Index);
            Q.Open (Model,
                    Path_Of (T.To_String (Item.Model_Path), (if Item.Image_Turbo then Turbo_Name else Denoiser_Name)),
                    Condition,
                    Panels => not On_Device);
            if E.Is_Ok (Condition) then
               Tk.Allocate (N.Element_Count (Q.Config (Model).Out_Channels * Rows * Columns), Latent);
               Last_Step := Ada.Calendar.Clock;
               Q.Sample (Model, Rows, Columns, Item.Image_Steps,
                         (if Item.Has_Seed then Item.Seed else Default_Seed), Text.all, Text_Rows, Team,
                         Latent.all, Condition, Say_Step'Access, Turbo => Item.Image_Turbo,
                         Guidance => Item.Image_Guidance,
                         Negative => (if Away = null then Q.No_Rows else Away.all), Negative_Rows => Away_Rows);
            end if;
            Q.Close (Model);
            Tk.Free (Text);
            Tk.Free (Away);
            if E.Is_Error (Condition) then
               Model_Runner.Backend.Device.Close;
               Fail (Condition);
               return;
            end if;
         end;

         --  The picture, written.
         declare
            VAE     : Dec.Picture_Decoder;
            Planes  : Tk.Real_Array_Access;
            Width   : constant Positive := Columns * Dec.Upscale;
            Height  : constant Positive := Rows * Dec.Upscale;
            Pixels  : constant N.Element_Count := N.Element_Count (Width * Height);
            File    : Model_Runner.Bytes.Byte_Array_Access;
         begin
            Dec.Open (VAE, Path_Of (T.To_String (Item.VAE_Path), VAE_Name), Condition);
            if E.Is_Ok (Condition) then
               Tk.Allocate (Pixels * Dec.Picture_Channels, Planes);
               Dec.Decode (VAE, Latent.all, Rows, Columns, Team, Planes.all, Condition);
            end if;
            Dec.Close (VAE);
            --  Open since the denoiser's, and its convolutions' too.
            Model_Runner.Backend.Device.Close;
            if E.Is_Ok (Condition) then
               Model_Runner.PNG_Writer.Encode
                 (Width, Height, Dec.Picture_Channels, Dec.To_Pixels (Planes.all, Pixels), File, Condition);
            end if;
            Tk.Free (Planes);
            Tk.Free (Latent);
            if E.Is_Ok (Condition) then
               declare
                  use Ada.Streams.Stream_IO;
                  Handle : File_Type;
                  Block  : Ada.Streams.Stream_Element_Array (1 .. Ada.Streams.Stream_Element_Offset (File'Length))
                    with Import, Address => File.all'Address;
               begin
                  Create (Handle, Out_File, T.To_String (Item.Image_Out));
                  Write (Handle, Block);
                  Close (Handle);
               exception
                  when others =>
                     Condition := E.Make (E.IO_Open_Failed);
                     E.Add_Text (Condition, "path", T.To_String (Item.Image_Out), E.Param_Path);
               end;
            end if;
            Model_Runner.Bytes.Free (File);
            if E.Is_Error (Condition) then
               Fail (Condition);
               return;
            end if;
            Pres.Put_Note (Screen, "cli.image.written",
                           [Model_Runner.Localization.Named ("path", T.To_String (Item.Image_Out))]);
         end;
         Status := E.Exit_Success;
      end Draw;
   begin
      Status := E.Exit_Success;
      --  The arithmetic the step was measured in: activations rounded to
      --  eight bits, its velocity the reference's at a cosine of 0.99999.
      Model_Runner.Backend.CPU.Use_Integer_Activations (Model_Runner.Backend.CPU.Every_Role);
      declare
         Wanted : constant Positive := Selected_Workers (Item);
      begin
         if Wanted = 1 then
            Draw (null);
         else
            declare
               Team : aliased Model_Runner.Backend.CPU.Pool (Model_Runner.Backend.CPU.Worker_Count (Wanted));
            begin
               Model_Runner.Backend.CPU.Open (Team);
               Draw (Team'Unchecked_Access);
               Model_Runner.Backend.CPU.Close (Team);
            exception
               when others =>
                  Model_Runner.Backend.CPU.Close (Team);
                  raise;
            end;
         end if;
      end;
   end Do_Image;

end Model_Runner.CLI.Execute.Image_Command;
