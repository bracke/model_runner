--  Video files, through FFmpeg's libraries opened by name.
--
--  Four libraries, each looked for under the names the versions this
--  reads are installed as and, failing those, the unversioned name a
--  development package leaves: libavformat, libavcodec, libavutil and
--  libswscale. The version is asked of libavformat before anything else
--  is used, since the offsets below are its version's.
--
--  The offsets. Every field read here was checked against the headers of
--  FFmpeg 6.1, 7.1 and 8.0 -- libavformat 60, 61 and 62 -- and sits at
--  the same place in all three:
--
--    AVFormatContext   streams 48
--    AVStream          index 8, codecpar 16, time_base 32, duration 48,
--                      nb_frames 56, avg_frame_rate 88
--    AVCodecParameters codec_type 0, codec_id 4
--    AVPacket          pts 8, dts 16, data 24, size 32, stream_index 36
--    AVFrame           data 0 (eight pointers), linesize 64 (eight ints),
--                      width 104, height 108, format 116
--
--  A libavformat of any other major version is refused, whatever the
--  rest, because the AVStream of 5 and before is laid out otherwise.
--
--  This directory is compiled for Linux and for macOS. The offsets are
--  the structures' own on a sixty-four-bit host of either, since nothing
--  in them is laid out by the operating system; what differs is the
--  library name, so each is looked for as a .so and as a .dylib. Checked
--  against Linux, with FFmpeg 6.1, where a video decoded. Not checked
--  against macOS: no Mac was to hand, and what is claimed for it is that
--  finding no library refuses a video file by name, which is the path a
--  Linux machine without one takes.
with Ada.Unchecked_Conversion;
with Interfaces.C.Strings;
with System.Storage_Elements;

with Model_Runner.Bytes;

package body Model_Runner.Platform.Video is

   package C renames Interfaces.C;
   package E renames Model_Runner.Errors;
   package B renames Model_Runner.Bytes;

   use type System.Address;
   use type System.Storage_Elements.Storage_Offset;
   use type C.int;
   use type C.unsigned;
   use type B.Byte_Array_Access;

   RTLD_NOW : constant C.int := 2;

   function dlopen
     (Name : C.Strings.chars_ptr; Flags : C.int) return System.Address
     with Import, Convention => C, External_Name => "dlopen";

   function dlsym
     (Handle : System.Address; Name : C.Strings.chars_ptr) return System.Address
     with Import, Convention => C, External_Name => "dlsym";

   --  The four libraries, opened once for the life of the program.
   Tried  : Boolean := False;
   Format_Library, Codec_Library, Util_Library, Scale_Library :
     System.Address := System.Null_Address;
   Reason : String (1 .. 160) := [others => ' '];
   Reason_Last : Natural := 0;

   --  The versions this reads, by libavformat's major.
   Least_Major : constant := 60;
   Most_Major  : constant := 62;

   ---------------------------------------------------------------------------
   --  The functions, as the libraries export them.

   type Open_Input is access function
     (Context : access System.Address; Path : C.Strings.chars_ptr;
      Input_Format, Options : System.Address) return C.int
     with Convention => C;
   type Context_Proc is access procedure (Context : access System.Address)
     with Convention => C;
   type Context_Function is access function
     (Context, Options : System.Address) return C.int
     with Convention => C;
   type Version_Function is access function return C.unsigned
     with Convention => C;
   type Find_Best_Stream is access function
     (Context : System.Address; Kind : C.int; Wanted, Related : C.int;
      Decoder : access System.Address; Flags : C.int) return C.int
     with Convention => C;
   type Alloc_Context is access function (Codec : System.Address)
     return System.Address
     with Convention => C;
   type Parameters_To_Context is access function
     (Context, Parameters : System.Address) return C.int
     with Convention => C;
   type Open_Codec is access function
     (Context, Codec, Options : System.Address) return C.int
     with Convention => C;
   type Alloc_Function is access function return System.Address
     with Convention => C;
   type Unref_Proc is access procedure (Item : System.Address)
     with Convention => C;
   type Read_Frame is access function
     (Context, Packet : System.Address) return C.int
     with Convention => C;
   type Send_Packet is access function
     (Context, Packet : System.Address) return C.int
     with Convention => C;
   type Receive_Frame is access function
     (Context, Frame : System.Address) return C.int
     with Convention => C;
   type Log_Level_Proc is access procedure (Level : C.int)
     with Convention => C;
   type Get_Scaler is access function
     (Source_Width, Source_Height, Source_Format : C.int;
      Target_Width, Target_Height, Target_Format : C.int;
      Flags : C.int; Source_Filter, Target_Filter, Parameters : System.Address)
     return System.Address
     with Convention => C;
   type Free_Scaler is access procedure (Scaler : System.Address)
     with Convention => C;

   type Plane_Addresses is array (0 .. 7) of System.Address
     with Convention => C;
   type Plane_Strides is array (0 .. 7) of C.int
     with Convention => C;
   type Scale is access function
     (Scaler : System.Address; Source : System.Address; Source_Stride : System.Address;
      Source_Row, Source_Height : C.int;
      Target : System.Address; Target_Stride : System.Address) return C.int
     with Convention => C;

   avformat_open_input       : Open_Input := null;
   avformat_close_input      : Context_Proc := null;
   avformat_find_stream_info : Context_Function := null;
   avformat_version          : Version_Function := null;
   av_find_best_stream       : Find_Best_Stream := null;
   av_read_frame             : Read_Frame := null;
   avcodec_alloc_context3    : Alloc_Context := null;
   avcodec_free_context      : Context_Proc := null;
   avcodec_parameters_to_context : Parameters_To_Context := null;
   avcodec_open2             : Open_Codec := null;
   avcodec_send_packet       : Send_Packet := null;
   avcodec_receive_frame     : Receive_Frame := null;
   av_packet_alloc           : Alloc_Function := null;
   av_packet_unref           : Unref_Proc := null;
   av_packet_free            : Context_Proc := null;
   av_frame_alloc            : Alloc_Function := null;
   av_frame_unref            : Unref_Proc := null;
   av_frame_free             : Context_Proc := null;
   av_log_set_level          : Log_Level_Proc := null;
   sws_getContext            : Get_Scaler := null;
   sws_scale                 : Scale := null;
   sws_freeContext           : Free_Scaler := null;

   --  The libraries' constants, from their headers.
   Media_Video   : constant C.int := 0;
   Pixel_RGB24   : constant C.int := 2;
   Bilinear      : constant C.int := 2;
   Error_EOF     : constant C.int := -541_478_725;
   Error_Again   : constant C.int := -11;
   Log_Quiet     : constant C.int := -8;

   --  The offsets, as the head of this file lists them.
   At_Streams        : constant := 48;
   At_Stream_Parameters : constant := 16;
   At_Stream_Frames  : constant := 56;
   At_Stream_Rate    : constant := 88;
   At_Parameters_Kind : constant := 0;
   At_Packet_Stream  : constant := 36;
   At_Frame_Data     : constant := 0;
   At_Frame_Strides  : constant := 64;
   At_Frame_Width    : constant := 104;
   At_Frame_Height   : constant := 108;
   At_Frame_Format   : constant := 116;

   ---------------------------------------------------------------------------

   procedure Say (Why : String) is
      Used : constant Natural := Natural'Min (Why'Length, Reason'Length);
   begin
      Reason (1 .. Used) := Why (Why'First .. Why'First + Used - 1);
      Reason_Last := Used;
   end Say;

   --  One library by its candidate names.
   function Open_Library (Stem : String; Majors : String) return System.Address
   is
      Result : System.Address := System.Null_Address;

      procedure Try (Name : String) is
         Text : C.Strings.chars_ptr := C.Strings.New_String (Name);
      begin
         if Result = System.Null_Address then
            Result := dlopen (Text, RTLD_NOW);
         end if;
         C.Strings.Free (Text);
      end Try;

      From : Positive := Majors'First;
   begin
      --  The versioned names first, newest first, then the unversioned.
      while From <= Majors'Last loop
         declare
            Stop : Natural := From;
         begin
            while Stop <= Majors'Last and then Majors (Stop) /= ' ' loop
               Stop := Stop + 1;
            end loop;
            Try (Stem & ".so." & Majors (From .. Stop - 1));
            Try (Stem & "." & Majors (From .. Stop - 1) & ".dylib");
            From := Stop + 1;
         end;
      end loop;
      Try (Stem & ".so");
      Try (Stem & ".dylib");
      return Result;
   end Open_Library;

   generic
      type Pointer is private;
   function Bound (Library : System.Address; Name : String) return Pointer;

   function Bound (Library : System.Address; Name : String) return Pointer is
      function To_Pointer is new Ada.Unchecked_Conversion (System.Address, Pointer);
      Text  : C.Strings.chars_ptr := C.Strings.New_String (Name);
      Found : constant System.Address := dlsym (Library, Text);
   begin
      C.Strings.Free (Text);
      if Found = System.Null_Address then
         Say ("the library lacks " & Name);
      end if;
      return To_Pointer (Found);
   end Bound;

   function Bind_Open_Input is new Bound (Open_Input);
   function Bind_Context_Proc is new Bound (Context_Proc);
   function Bind_Context_Function is new Bound (Context_Function);
   function Bind_Version is new Bound (Version_Function);
   function Bind_Find_Best_Stream is new Bound (Find_Best_Stream);
   function Bind_Alloc_Context is new Bound (Alloc_Context);
   function Bind_Parameters_To_Context is new Bound (Parameters_To_Context);
   function Bind_Open_Codec is new Bound (Open_Codec);
   function Bind_Alloc_Function is new Bound (Alloc_Function);
   function Bind_Unref_Proc is new Bound (Unref_Proc);
   function Bind_Read_Frame is new Bound (Read_Frame);
   function Bind_Send_Packet is new Bound (Send_Packet);
   function Bind_Receive_Frame is new Bound (Receive_Frame);
   function Bind_Log_Level is new Bound (Log_Level_Proc);
   function Bind_Get_Scaler is new Bound (Get_Scaler);
   function Bind_Scale is new Bound (Scale);
   function Bind_Free_Scaler is new Bound (Free_Scaler);

   --  Open the four libraries, once, check the version, and find the
   --  functions.
   procedure Load is
   begin
      if Tried then
         return;
      end if;
      Tried := True;

      Format_Library := Open_Library ("libavformat", "62 61 60");
      if Format_Library = System.Null_Address then
         Say ("libavformat is not installed");
         return;
      end if;
      avformat_version := Bind_Version (Format_Library, "avformat_version");
      if avformat_version = null then
         Format_Library := System.Null_Address;
         return;
      end if;
      declare
         Major : constant Natural :=
           Natural (avformat_version.all / 2 ** 16);
      begin
         if Major < Least_Major or else Major > Most_Major then
            Say ("libavformat" & Natural'Image (Major)
                 & " is not a version this build reads; 60 to 62 are");
            Format_Library := System.Null_Address;
            return;
         end if;
      end;

      Codec_Library := Open_Library ("libavcodec", "62 61 60");
      Util_Library  := Open_Library ("libavutil", "60 59 58");
      Scale_Library := Open_Library ("libswscale", "9 8 7");
      if Codec_Library = System.Null_Address then
         Say ("libavcodec is not installed");
      elsif Util_Library = System.Null_Address then
         Say ("libavutil is not installed");
      elsif Scale_Library = System.Null_Address then
         Say ("libswscale is not installed");
      end if;
      if Codec_Library = System.Null_Address
        or else Util_Library = System.Null_Address
        or else Scale_Library = System.Null_Address
      then
         Format_Library := System.Null_Address;
         return;
      end if;

      avformat_open_input := Bind_Open_Input (Format_Library, "avformat_open_input");
      avformat_close_input := Bind_Context_Proc (Format_Library, "avformat_close_input");
      avformat_find_stream_info :=
        Bind_Context_Function (Format_Library, "avformat_find_stream_info");
      av_find_best_stream := Bind_Find_Best_Stream (Format_Library, "av_find_best_stream");
      av_read_frame := Bind_Read_Frame (Format_Library, "av_read_frame");
      avcodec_alloc_context3 := Bind_Alloc_Context (Codec_Library, "avcodec_alloc_context3");
      avcodec_free_context := Bind_Context_Proc (Codec_Library, "avcodec_free_context");
      avcodec_parameters_to_context :=
        Bind_Parameters_To_Context (Codec_Library, "avcodec_parameters_to_context");
      avcodec_open2 := Bind_Open_Codec (Codec_Library, "avcodec_open2");
      avcodec_send_packet := Bind_Send_Packet (Codec_Library, "avcodec_send_packet");
      avcodec_receive_frame := Bind_Receive_Frame (Codec_Library, "avcodec_receive_frame");
      av_packet_alloc := Bind_Alloc_Function (Codec_Library, "av_packet_alloc");
      av_packet_unref := Bind_Unref_Proc (Codec_Library, "av_packet_unref");
      av_packet_free := Bind_Context_Proc (Codec_Library, "av_packet_free");
      av_frame_alloc := Bind_Alloc_Function (Util_Library, "av_frame_alloc");
      av_frame_unref := Bind_Unref_Proc (Util_Library, "av_frame_unref");
      av_frame_free := Bind_Context_Proc (Util_Library, "av_frame_free");
      av_log_set_level := Bind_Log_Level (Util_Library, "av_log_set_level");
      sws_getContext := Bind_Get_Scaler (Scale_Library, "sws_getContext");
      sws_scale := Bind_Scale (Scale_Library, "sws_scale");
      sws_freeContext := Bind_Free_Scaler (Scale_Library, "sws_freeContext");

      if avformat_open_input = null or else avformat_close_input = null
        or else avformat_find_stream_info = null
        or else av_find_best_stream = null or else av_read_frame = null
        or else avcodec_alloc_context3 = null or else avcodec_free_context = null
        or else avcodec_parameters_to_context = null or else avcodec_open2 = null
        or else avcodec_send_packet = null or else avcodec_receive_frame = null
        or else av_packet_alloc = null or else av_packet_unref = null
        or else av_packet_free = null or else av_frame_alloc = null
        or else av_frame_unref = null or else av_frame_free = null
        or else sws_getContext = null or else sws_scale = null
        or else sws_freeContext = null
      then
         Format_Library := System.Null_Address;
         return;
      end if;

      --  The libraries talk on standard error unless told not to, and
      --  what they say is theirs; a refusal here names the file.
      if av_log_set_level /= null then
         av_log_set_level (Log_Quiet);
      end if;
      Reason_Last := 0;
   end Load;

   function Is_Supported return Boolean is
   begin
      Load;
      return Format_Library /= System.Null_Address;
   end Is_Supported;

   function Unsupported_Reason return String is
   begin
      Load;
      return Reason (1 .. Reason_Last);
   end Unsupported_Reason;

   ---------------------------------------------------------------------------
   --  Reading the libraries' structures at their offsets.

   function Int_At (Base : System.Address; Offset : Natural) return Integer is
      Item : C.int
        with Import, Address => Base + System.Storage_Elements.Storage_Offset (Offset);
   begin
      return Integer (Item);
   end Int_At;

   function Long_At (Base : System.Address; Offset : Natural) return Long_Long_Integer
   is
      Item : Interfaces.Integer_64
        with Import, Address => Base + System.Storage_Elements.Storage_Offset (Offset);
   begin
      return Long_Long_Integer (Item);
   end Long_At;

   function Address_At (Base : System.Address; Offset : Natural) return System.Address
   is
      Item : System.Address
        with Import, Address => Base + System.Storage_Elements.Storage_Offset (Offset);
   begin
      return Item;
   end Address_At;

   procedure Refuse
     (Status : out E.Error_Info; Path : String; Why : String) is
   begin
      Status := E.Make (E.IO_Video_Unreadable);
      E.Add_Text (Status, "path", Path, E.Param_Path);
      E.Add_Text (Status, "detail", Why, E.Param_Text);
   end Refuse;

   --  Open the container and the decoder of its first video stream.
   procedure Open_Stream
     (Item   : in out Reader;
      Path   : String;
      Status : out E.Error_Info)
   is
      Text    : C.Strings.chars_ptr := C.Strings.New_String (Path);
      Context : aliased System.Address := System.Null_Address;
      Decoder : aliased System.Address := System.Null_Address;
      Result  : C.int;
   begin
      Status := E.Success;
      Result := avformat_open_input
        (Context'Access, Text, System.Null_Address, System.Null_Address);
      C.Strings.Free (Text);
      if Result < 0 or else Context = System.Null_Address then
         Refuse (Status, Path, "the file is not a video the libraries read");
         return;
      end if;
      Item.Format := Context;

      if avformat_find_stream_info (Context, System.Null_Address) < 0 then
         Refuse (Status, Path, "the file's streams could not be read");
         return;
      end if;

      Result := av_find_best_stream
        (Context, Media_Video, -1, -1, Decoder'Access, 0);
      if Result < 0 or else Decoder = System.Null_Address then
         Refuse (Status, Path, "the file has no video stream this build decodes");
         return;
      end if;
      Item.Stream := Integer (Result);

      declare
         Streams : constant System.Address := Address_At (Context, At_Streams);
         Stream  : constant System.Address :=
           Address_At (Streams, Item.Stream * (System.Address'Size / 8));
         Parameters : constant System.Address :=
           Address_At (Stream, At_Stream_Parameters);
         Numerator : constant Integer := Int_At (Stream, At_Stream_Rate);
         Denominator : constant Integer := Int_At (Stream, At_Stream_Rate + 4);
      begin
         if Int_At (Parameters, At_Parameters_Kind) /= Integer (Media_Video) then
            Refuse (Status, Path, "the stream found is not a video stream");
            return;
         end if;
         if Numerator <= 0 or else Denominator <= 0 then
            Refuse (Status, Path, "the file states no frame rate");
            return;
         end if;
         Item.Per_Second := Long_Float (Numerator) / Long_Float (Denominator);

         Item.Codec := avcodec_alloc_context3 (Decoder);
         if Item.Codec = System.Null_Address
           or else avcodec_parameters_to_context (Item.Codec, Parameters) < 0
           or else avcodec_open2 (Item.Codec, Decoder, System.Null_Address) < 0
         then
            Refuse (Status, Path, "the stream's decoder would not open");
            return;
         end if;
      end;

      Item.Frame := av_frame_alloc.all;
      Item.Packet := av_packet_alloc.all;
      if Item.Frame = System.Null_Address or else Item.Packet = System.Null_Address
      then
         Status := E.Make (E.Memory_Allocation_Failed);
         E.Add_Text (Status, "category", "video", E.Param_Identifier);
      end if;
   end Open_Stream;

   --  Release what Open_Stream took, keeping the counts.
   procedure Release (Item : in out Reader) is
   begin
      if Item.Scaler /= System.Null_Address then
         sws_freeContext (Item.Scaler);
         Item.Scaler := System.Null_Address;
      end if;
      if Item.Frame /= System.Null_Address then
         declare
            Held : aliased System.Address := Item.Frame;
         begin
            av_frame_free (Held'Access);
         end;
         Item.Frame := System.Null_Address;
      end if;
      if Item.Packet /= System.Null_Address then
         declare
            Held : aliased System.Address := Item.Packet;
         begin
            av_packet_free (Held'Access);
         end;
         Item.Packet := System.Null_Address;
      end if;
      if Item.Codec /= System.Null_Address then
         declare
            Held : aliased System.Address := Item.Codec;
         begin
            avcodec_free_context (Held'Access);
         end;
         Item.Codec := System.Null_Address;
      end if;
      if Item.Format /= System.Null_Address then
         declare
            Held : aliased System.Address := Item.Format;
         begin
            avformat_close_input (Held'Access);
         end;
         Item.Format := System.Null_Address;
      end if;
      Item.Scaled_Format := -1;
      Item.Scaled_Width := 0;
      Item.Scaled_Height := 0;
      Item.Drained := False;
   end Release;

   ----------
   -- Open --
   ----------

   procedure Open
     (Item   : in out Reader;
      Path   : String;
      Status : out E.Error_Info)
   is
      Stated : Long_Long_Integer;
   begin
      Close (Item);
      Status := E.Success;

      if not Is_Supported then
         Refuse (Status, Path, Unsupported_Reason);
         return;
      end if;

      Open_Stream (Item, Path, Status);
      if E.Is_Error (Status) then
         Release (Item);
         return;
      end if;

      --  The frame count and size, from the stream; where the container
      --  states no count, the packets are counted in a pass of their own,
      --  and the file opened afresh for the frames.
      declare
         Streams : constant System.Address := Address_At (Item.Format, At_Streams);
         Stream  : constant System.Address :=
           Address_At (Streams, Item.Stream * (System.Address'Size / 8));
      begin
         Stated := Long_At (Stream, At_Stream_Frames);
      end;

      if Stated > 0 then
         Item.Count := Positive (Stated);
      else
         declare
            Counted : Natural := 0;
         begin
            while av_read_frame (Item.Format, Item.Packet) >= 0 loop
               if Int_At (Item.Packet, At_Packet_Stream) = Item.Stream then
                  Counted := Counted + 1;
               end if;
               av_packet_unref (Item.Packet);
            end loop;
            Release (Item);
            if Counted = 0 then
               Refuse (Status, Path, "the video stream holds no frames");
               return;
            end if;
            Open_Stream (Item, Path, Status);
            if E.Is_Error (Status) then
               Release (Item);
               return;
            end if;
            Item.Count := Counted;
         end;
      end if;

      --  The frames' size is a decoded frame's, read on the first Next;
      --  until then Width and Height say one.
      Item.Ready := True;
   end Open;

   -----------
   -- Close --
   -----------

   procedure Close (Item : in out Reader) is
   begin
      if Format_Library /= System.Null_Address then
         Release (Item);
      end if;
      Item.Ready := False;
      Item.Stream := -1;
      Item.Count := 1;
      Item.Per_Second := 1.0;
      Item.Wide := 1;
      Item.Tall := 1;
   end Close;

   function Is_Open (Item : Reader) return Boolean is (Item.Ready);
   function Frames (Item : Reader) return Positive is (Item.Count);
   function Rate (Item : Reader) return Long_Float is (Item.Per_Second);
   function Width (Item : Reader) return Positive is (Item.Wide);
   function Height (Item : Reader) return Positive is (Item.Tall);

   ----------
   -- Next --
   ----------

   procedure Next
     (Item    : in out Reader;
      Picture : out Model_Runner.Images.Raster;
      Done    : out Boolean;
      Status  : out E.Error_Info)
   is
      Result : C.int;
   begin
      Picture := (others => <>);
      Done := False;
      Status := E.Success;

      if not Item.Ready then
         Status := E.Make (E.Lifecycle_Model_Not_Ready);
         return;
      end if;

      --  A decoded frame where the decoder has one; else the next packet
      --  of the stream sent to it, and the stream's end sent as the
      --  packet that says so.
      loop
         Result := avcodec_receive_frame (Item.Codec, Item.Frame);
         exit when Result >= 0;
         if Result = Error_EOF then
            Done := True;
            return;
         elsif Result /= Error_Again then
            Refuse (Status, "", "the decoder refused a frame");
            return;
         end if;

         if Item.Drained then
            Done := True;
            return;
         end if;

         loop
            Result := av_read_frame (Item.Format, Item.Packet);
            if Result < 0 then
               Item.Drained := True;
               Result := avcodec_send_packet (Item.Codec, System.Null_Address);
               exit;
            elsif Int_At (Item.Packet, At_Packet_Stream) = Item.Stream then
               Result := avcodec_send_packet (Item.Codec, Item.Packet);
               av_packet_unref (Item.Packet);
               exit;
            else
               av_packet_unref (Item.Packet);
            end if;
         end loop;
      end loop;

      --  The frame, converted to rows of RGB through a scaler made for
      --  its size and format and kept while they stay the same.
      declare
         Wide   : constant Integer := Int_At (Item.Frame, At_Frame_Width);
         Tall   : constant Integer := Int_At (Item.Frame, At_Frame_Height);
         Format : constant Integer := Int_At (Item.Frame, At_Frame_Format);
      begin
         if Wide <= 0 or else Tall <= 0 then
            av_frame_unref (Item.Frame);
            Refuse (Status, "", "the decoder handed out an empty frame");
            return;
         end if;
         Item.Wide := Wide;
         Item.Tall := Tall;

         if Item.Scaler = System.Null_Address
           or else Item.Scaled_Format /= Format
           or else Item.Scaled_Width /= Wide or else Item.Scaled_Height /= Tall
         then
            if Item.Scaler /= System.Null_Address then
               sws_freeContext (Item.Scaler);
            end if;
            Item.Scaler := sws_getContext
              (C.int (Wide), C.int (Tall), C.int (Format),
               C.int (Wide), C.int (Tall), Pixel_RGB24, Bilinear,
               System.Null_Address, System.Null_Address, System.Null_Address);
            Item.Scaled_Format := Format;
            Item.Scaled_Width := Wide;
            Item.Scaled_Height := Tall;
            if Item.Scaler = System.Null_Address then
               av_frame_unref (Item.Frame);
               Refuse (Status, "", "the frame's pixel format has no conversion");
               return;
            end if;
         end if;

         --  Indexed from nought, as a raster's pixels are.
         begin
            Picture.Pixels :=
              new B.Byte_Array'(0 .. B.Byte_Count (3 * Wide * Tall - 1) => 0);
         exception
            when Storage_Error =>
               Picture.Pixels := null;
         end;
         if Picture.Pixels = null then
            av_frame_unref (Item.Frame);
            Status := E.Make (E.Memory_Allocation_Failed);
            E.Add_Text (Status, "category", "video", E.Param_Identifier);
            return;
         end if;
         Picture.Width := Wide;
         Picture.Height := Tall;

         declare
            Target  : aliased Plane_Addresses :=
              [0 => Picture.Pixels.all'Address, others => System.Null_Address];
            Strides : aliased Plane_Strides := [0 => C.int (3 * Wide), others => 0];
         begin
            Result := sws_scale
              (Item.Scaler,
               Item.Frame + At_Frame_Data, Item.Frame + At_Frame_Strides,
               0, C.int (Tall), Target'Address, Strides'Address);
         end;
         av_frame_unref (Item.Frame);
         if Result <= 0 then
            Model_Runner.Images.Free (Picture);
            Refuse (Status, "", "the frame could not be converted to RGB");
            return;
         end if;
      end;
   end Next;

end Model_Runner.Platform.Video;
