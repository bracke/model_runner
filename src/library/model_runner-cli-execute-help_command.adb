with Model_Runner.GGUF;
with Model_Runner.Backend;
with Model_Runner.Quantization;
with Model_Runner.Platform;
with Model_Runner.Platform.Device;
with Model_Runner.Templates;

package body Model_Runner.CLI.Execute.Help_Command is

   use type Opt.Command_Kind;

   ---------------------------------------------------------------------------
   --  help and version
   ---------------------------------------------------------------------------

   --  The chat formats this build carries, in the order they are
   --  declared. Written out beside the option before this, where it said
   --  "llama3 or chatml" and would have gone on saying it.
   function Format_Names return String is
      Room : String (1 .. 256);
      Used : Natural := 0;

      procedure Add (Text : String) is
      begin
         if Used + Text'Length <= Room'Length then
            Room (Used + 1 .. Used + Text'Length) := Text;
            Used := Used + Text'Length;
         end if;
      end Add;
   begin
      for Format in Model_Runner.Templates.Chat_Format loop
         if Used > 0 then
            Add (", ");
         end if;
         Add (Model_Runner.Templates.Format_Name (Format));
      end loop;
      return Room (1 .. Used);
   end Format_Names;

   --  The backends this build has, in the order they are declared.
   function Backend_Names return String is
      Room : String (1 .. 256);
      Used : Natural := 0;

      procedure Add (Text : String) is
      begin
         if Used + Text'Length <= Room'Length then
            Room (Used + 1 .. Used + Text'Length) := Text;
            Used := Used + Text'Length;
         end if;
      end Add;
   begin
      for Kind in Model_Runner.Backend.Backend_Kind loop
         if Used > 0 then
            Add (", ");
         end if;
         Add (Model_Runner.Backend.Backend_Name (Kind));
      end loop;
      return Room (1 .. Used);
   end Backend_Names;

   --  The architectures this build reads, in the order they are declared.
   function Architecture_Names return String is
      Room : String (1 .. 128);
      Used : Natural := 0;

      procedure Add (Text : String) is
      begin
         if Used + Text'Length <= Room'Length then
            Room (Used + 1 .. Used + Text'Length) := Text;
            Used := Used + Text'Length;
         end if;
      end Add;
   begin
      for Kind in L.Architecture loop
         if Used > 0 then
            Add (", ");
         end if;
         Add (L.Architecture_Name (Kind));
      end loop;
      return Room (1 .. Used);
   end Architecture_Names;

   --  The tensor formats this build decodes, in the order they are declared.
   function Decodable_Formats return String is
      Room : String (1 .. 256);
      Used : Natural := 0;

      procedure Add (Text : String) is
      begin
         if Used + Text'Length <= Room'Length then
            Room (Used + 1 .. Used + Text'Length) := Text;
            Used := Used + Text'Length;
         end if;
      end Add;
   begin
      for Format in Model_Runner.GGUF.Tensor_Type loop
         if Model_Runner.Quantization.Is_Decodable (Format) then
            if Used > 0 then
               Add (", ");
            end if;
            Add (Model_Runner.GGUF.Type_Name (Format));
         end if;
      end loop;
      return Room (1 .. Used);
   end Decodable_Formats;

   procedure Show_Version (Screen : in out Pres.Console) is
   begin
      Screen.Put_Message
        ("application.version", [Loc.Named ("version", Model_Runner.Version)]);
      Screen.Put_Message
        ("application.license", [Loc.Named ("license", Model_Runner.License)]);
      Screen.Put_Message
        ("application.architecture",
         [Loc.Named ("name", Architecture_Names)]);

      --  What this build can actually take, asked of the build. Someone
      --  running version wants to know whether their file will open, and
      --  the answer was one architecture name and nothing else -- while the
      --  program could already list its formats, its backends and its chat
      --  formats for itself, and does, in help.
      Screen.Put_Message
        ("application.formats", [Loc.Named ("value", Decodable_Formats)]);
      Screen.Put_Message
        ("application.backends", [Loc.Named ("value", Backend_Names)]);
      Screen.Put_Message
        ("application.chat_formats", [Loc.Named ("value", Format_Names)]);

      --  And what the machine has, which is a different question from what
      --  the build can do. Nothing runs on a device yet; this reports what
      --  one would run on, so that a reader can tell "this build cannot" from
      --  "this machine has none" before either becomes a surprise.
      declare
         package Devices renames Model_Runner.Platform.Device;

         Held  : Devices.Inventory;
         Found : Boolean;

         Room : String (1 .. 512) := [others => ' '];
         Used : Natural := 0;

         procedure Add (Text : String) is
         begin
            if Used + Text'Length <= Room'Last then
               Room (Used + 1 .. Used + Text'Length) := Text;
               Used := Used + Text'Length;
            end if;
         end Add;
      begin
         Devices.Open (Held, Found);

         for Index in 1 .. Devices.Count (Held) loop
            if Used > 0 then
               Add (", ");
            end if;
            Add (Devices.Name (Held, Index));

            --  Whether it has its own memory, because that is what decides
            --  whether moving a model to it costs anything -- or is the
            --  processor itself behind the interface, a software rasterizer
            --  a host lists beside its real device, which is neither.
            Add ((if Devices.Is_Software (Held, Index)
                  then " (software)"
                  elsif Devices.Is_Discrete (Held, Index)
                  then " (discrete)"
                  else " (integrated)"));
         end loop;

         Screen.Put_Message
           ("application.devices",
            [Loc.Named ("value",
                        (if Used = 0 then "none" else Room (1 .. Used)))]);

         Devices.Close (Held);
      end;
   end Show_Version;

   procedure Show_Help
     (Screen : in out Pres.Console;
      Topic  : String)
   is

      --  Emit a block of help lines, each an independent catalog entry so
      --  that a translation can reflow a line without breaking the layout.
      --
      --  An entry's name is the catalog key and its value, when it has one,
      --  is what the line's {value} stands for. That is how a line listing
      --  what this build carries stays in the block with the rest instead of
      --  being printed beside it and losing its indentation.
      --  Every option a command takes, in the order the registry holds
      --  them, each with the line that documents it.
      --
      --  The lists used to be written out here beside a parser that
      --  accepted a different set: `inspect` documented five options and
      --  took thirty-seven, and --quiet and --verbose worked there while
      --  appearing only under run. Generated from the registry, a help
      --  screen cannot say less than the command accepts.
      procedure Options_Of (Kind : Opt.Command_Kind; Topic_Name : String) is
      begin
         for Index in 1 .. Opt.Option_Count loop
            if Opt.Option_Commands (Index) (Kind)
              and then Opt.Option_Help (Index) /= ""
            then
               declare
                  Key : constant String :=
                    "help." & Topic_Name & "." & Opt.Option_Help (Index);

                  --  Three lines name what this build carries rather than
                  --  a list somebody typed. The value goes in as an
                  --  argument so the sentence around it stays localized.
                  Value : constant String :=
                    (if Opt.Option_Name (Index) = "--repack"
                     then Opt.Repack_Names
                     elsif Opt.Option_Name (Index) = "--kv-cache"
                     then Opt.Cache_Names
                     elsif Opt.Option_Name (Index) = "--kv-values"
                     then Opt.Value_Names
                     elsif Opt.Option_Name (Index) = "--arith"
                     then Opt.Arithmetic_Names
                     elsif Opt.Option_Name (Index) = "--pooling"
                     then Opt.Pooling_Names
                     elsif Opt.Option_Name (Index) = "--color"
                     then Opt.Color_Names
                     elsif Opt.Option_Name (Index) = "--backend"
                     then Backend_Names
                     elsif Opt.Option_Name (Index) = "--chat-template"
                     then Format_Names
                     else "");
               begin
                  Screen.Put_Option (Key, [Loc.Named ("value", Value)]);
               end;
            end if;
         end loop;
      end Options_Of;

   begin
      --  Dispatched on the command a topic names rather than on the word,
      --  and every screen builds its keys from that command's word. The
      --  chain here used to name the four topics beside a Command_Kind that
      --  already named exactly those four, so a fifth command would have
      --  compiled, dispatched, taken options -- and had no help.
      case Opt.Command_Of (Topic) is
         when Opt.Command_Run | Opt.Command_Embed | Opt.Command_Inspect =>
            declare
               Kind : constant Opt.Command_Kind := Opt.Command_Of (Topic);
               Word : constant String := Opt.Command_Word (Kind);
            begin
               Screen.Put_Message ("help." & Word & ".usage");
               Screen.Put_Line ("");
               Screen.Put_Message ("help." & Word & ".summary");

               Screen.Put_Line ("");
               Screen.Put_Message ("help." & Word & ".options");
               Options_Of (Kind, Word);

               --  Where the output goes and what is never written down are
               --  properties of a run, and are said where a run is
               --  explained.
               if Kind = Opt.Command_Run then
                  Screen.Put_Line ("");
                  Screen.Put_Message ("help.run.streams");
                  Screen.Put_Message ("help.run.privacy");
               elsif Kind = Opt.Command_Embed then
                  Screen.Put_Line ("");
                  Screen.Put_Message ("help.embed.streams");
               end if;
            end;

         when Opt.Command_Help | Opt.Command_Version
            | Opt.Command_Models =>
            declare
               Word : constant String :=
                 Opt.Command_Word (Opt.Command_Of (Topic));
            begin
               Screen.Put_Message ("help." & Word & ".usage");
               Screen.Put_Line ("");
               Screen.Put_Message ("help." & Word & ".summary");
            end;

         when Opt.Command_None =>
            --  No topic. A topic naming no command never reaches here: the
            --  parser refuses it the way it refuses the same word typed as
            --  a command.
            Screen.Put_Message ("application.summary");
            Screen.Put_Line ("");
            Screen.Put_Message ("cli.general.usage");
            Screen.Put_Line ("");
            Screen.Put_Message ("cli.general.commands");

            for Kind in Opt.Command_Kind loop
               if Kind /= Opt.Command_None then
                  Screen.Put_Option
                    ("cli.general.command." & Opt.Command_Word (Kind),
                     [Loc.Named ("value", "")]);
               end if;
            end loop;

            Screen.Put_Line ("");
            Screen.Put_Message ("cli.general.more");
            Screen.Put_Message ("cli.general.exit_statuses");
      end case;
   end Show_Help;

end Model_Runner.CLI.Execute.Help_Command;
