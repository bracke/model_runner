with Model_Runner.Backend;
with Ada.Strings.Fixed;
with Interfaces;
with Model_Runner.Conversation;
with Model_Runner.Quantization;
with Model_Runner.Quantization.Interleave;
with Model_Runner.Memory;
with Model_Runner.Platform;
with Model_Runner.Templates;
with Model_Runner.CLI.Execute.Acquisition;

package body Model_Runner.CLI.Execute.Inspect_Command is

   use Model_Runner.CLI.Execute.Acquisition;
   use type Interfaces.Unsigned_64;
   use type Model_Runner.CLI.Options.Verbosity;
   use type Model_Runner.Conversation.Role;
   use type L.Pooling_Choice;

   ---------------------------------------------------------------------------
   --  inspect
   ---------------------------------------------------------------------------

   procedure Do_Inspect
     (Item    : Opt.Command;
      Screen  : in out Pres.Console;
      Status  : out Natural)
   is
      Source    : Shards.Shard_Set;
      Container : Containers.Container;
      Prepared  : L.Model;
      Condition : E.Error_Info;
      Ignored   : E.Error_Info;

      --  The first refusal this inspection printed, if any. The report goes
      --  on past it; the status does not pretend it did not happen.
      Refused   : E.Error_Info;

      --  A size as a reader takes it in, and exact for a program reading
      --  the structured report.
      function Size_Said (Bytes : Interfaces.Unsigned_64) return String
      is (if Pres.Is_Structured (Screen) then T.Image (Long_Long_Integer (Bytes)) else Pres.Size_Image (Bytes));

      --  The same, without the exact count in brackets.
      function Short_Size (Bytes : Interfaces.Unsigned_64) return String is
         Said : constant String := Pres.Size_Image (Bytes);
         Cut  : constant Natural := Ada.Strings.Fixed.Index (Said, " (");
      begin
         return (if Cut = 0 then Said else Said (Said'First .. Cut - 1));
      end Short_Size;
   begin
      Load
        (Item, Screen, Source, Container, Prepared, False, null, null,
         Condition);

      if E.Is_Error (Condition) then
         Pres.Report (Screen, Condition);
         Shards.Close (Source);
         Status := E.Exit_Status (Condition);
         return;
      end if;

      if Item.Validate_Only then
         --  The container is sound; whether this build can use the model is
         --  the other half of the question, and the verdict is the whole of
         --  what this option prints. It used to answer only the first half:
         --  a model whose architecture this build does not implement was
         --  called valid and left with a success, while `run` on the same
         --  file refuses it and leaves with four.
         declare
            Settings : L.Configuration;
            Detail   : E.Error_Info;
         begin
            L.Read_Config (Container, Model_Bounds (Item), Settings, Detail);

            if E.Is_Error (Detail) then
               Pres.Report (Screen, Detail);
               Status := E.Exit_Status (Detail);
            else
               Screen.Put_Message ("cli.inspect.valid");
               Status := E.Exit_Success;
            end if;
         end;

         Containers.Close (Container);
         Shards.Close (Source);
         return;
      end if;

      Pres.Put_Heading (Screen, "cli.inspect.heading.container", Pres.Answer);
      Pres.Put_Field
        (Screen, "cli.inspect.label.path",
         T.Escape_Controls (T.To_String (Item.Model_Path)), Pres.Answer);
      Pres.Put_Field
        (Screen, "cli.inspect.label.file_size",
         Size_Said (Interfaces.Unsigned_64 (Containers.File_Size (Container))), Pres.Answer);
      Pres.Put_Field
        (Screen, "cli.inspect.label.gguf_version",
         T.Image (Long_Long_Integer (Containers.Version (Container))), Pres.Answer);
      Pres.Put_Field
        (Screen, "cli.inspect.label.alignment",
         T.Image (Long_Long_Integer (Containers.Alignment (Container))), Pres.Answer);
      Pres.Put_Field
        (Screen, "cli.inspect.label.metadata_count",
         T.Image (Long_Long_Integer (Containers.Metadata_Count (Container))), Pres.Answer);
      Pres.Put_Field
        (Screen, "cli.inspect.label.tensor_count",
         T.Image (Long_Long_Integer (Containers.Tensor_Count (Container))), Pres.Answer);

      --  Parameter count and the set of formats actually used.
      declare
         Parameters : Interfaces.Unsigned_64 := 0;
         Formats    : array (G.Tensor_Type) of Boolean := [others => False];
         Listing    : String (1 .. 256);
         Filled     : Natural := 0;
      begin
         for Index in 1 .. Containers.Tensor_Count (Container) loop
            Parameters :=
              Parameters + Containers.Tensor_Elements (Container, Index);
            Formats (Containers.Tensor_Format (Container, Index)) := True;
         end loop;

         for Format in G.Tensor_Type loop
            if Formats (Format) then
               declare
                  Name : constant String := G.Type_Name (Format);
               begin
                  if Filled + Name'Length + 2 <= Listing'Length then
                     if Filled > 0 then
                        Listing (Filled + 1 .. Filled + 2) := ", ";
                        Filled := Filled + 2;
                     end if;
                     Listing (Filled + 1 .. Filled + Name'Length) := Name;
                     Filled := Filled + Name'Length;
                  end if;
               end;
            end if;
         end loop;

         Pres.Put_Field
           (Screen, "cli.inspect.label.parameters",
            (if Pres.Is_Structured (Screen) or else Interfaces."<" (Parameters, 1_000_000)
             then T.Image (Long_Long_Integer (Parameters))
             else T.Image (Long_Float (Parameters) / 1.0E6, 1) & " million ("
                  & T.Image (Long_Long_Integer (Parameters)) & ")"), Pres.Answer);
         Pres.Put_Field
           (Screen, "cli.inspect.label.formats", Listing (1 .. Filled), Pres.Answer);
         Pres.Put_Field
           (Screen, "cli.inspect.label.mapped",
            Screen.Message_Value
              (if Shards.Is_Mapped (Source)
               then "cli.inspect.value.yes"
               else "cli.inspect.value.no"), Pres.Answer);
      end;

      --  Architecture, read from metadata without loading any weights.
      declare
         Settings : L.Configuration;
         Detail   : E.Error_Info;
      begin
         L.Read_Config (Container, Model_Bounds (Item), Settings, Detail);

         if E.Is_Error (Detail) then
            --  Reported and remembered. The rest of the report is still
            --  worth printing -- a reader inspecting a file this build
            --  cannot run wants to see what is in it -- but a command that
            --  printed an error and left with a success told a script the
            --  file was fine.
            Pres.Report (Screen, Detail);
            Refused := Detail;
         else
            Pres.Put_Heading (Screen, "cli.inspect.heading.architecture", Pres.Answer, Gap => True);
            Pres.Put_Field
              (Screen, "cli.inspect.label.name",
               T.Escape_Controls
                 (Containers.String_Value (Container, "general.name")), Pres.Answer);
            Pres.Put_Field
              (Screen, "cli.inspect.label.architecture",
               Containers.String_Value (Container, "general.architecture"), Pres.Answer);
            Pres.Put_Field
              (Screen, "cli.inspect.label.context_length",
               T.Image (Long_Long_Integer (Settings.Context_Length)), Pres.Answer);
            Pres.Put_Field
              (Screen, "cli.inspect.label.embedding",
               T.Image (Long_Long_Integer (Settings.Embedding)), Pres.Answer);
            Pres.Put_Field
              (Screen, "cli.inspect.label.feed_forward",
               T.Image (Long_Long_Integer (Settings.Feed_Forward)), Pres.Answer);
            --  The mixture, for a file that has one. Without these the
            --  report names a feed-forward width and nothing else, and for
            --  a model whose feed-forward block sits behind a router that
            --  width belongs to a block the model does not have: the file
            --  states it, the engine computes with the expert's, and a
            --  reader shown only the first is reading about another model.
            if Settings.Experts > 0 then
               Pres.Put_Field
                 (Screen, "cli.inspect.label.experts",
                  T.Image (Long_Long_Integer (Settings.Experts)),
                  Pres.Answer);
               Pres.Put_Field
                 (Screen, "cli.inspect.label.experts_used",
                  T.Image (Long_Long_Integer (Settings.Experts_Used)),
                  Pres.Answer);
               Pres.Put_Field
                 (Screen, "cli.inspect.label.expert_feed_forward",
                  T.Image (Long_Long_Integer (Settings.Expert_Feed)),
                  Pres.Answer);
            end if;

            Pres.Put_Field
              (Screen, "cli.inspect.label.layers",
               T.Image (Long_Long_Integer (Settings.Layers)), Pres.Answer);
            Pres.Put_Field
              (Screen, "cli.inspect.label.heads",
               T.Image (Long_Long_Integer (Settings.Heads)), Pres.Answer);
            Pres.Put_Field
              (Screen, "cli.inspect.label.kv_heads",
               T.Image (Long_Long_Integer (Settings.KV_Heads)), Pres.Answer);
            Pres.Put_Field
              (Screen, "cli.inspect.label.head_size",
               T.Image (Long_Long_Integer (Settings.Head_Size)), Pres.Answer);
            Pres.Put_Field
              (Screen, "cli.inspect.label.rope_dimension",
               T.Image (Long_Long_Integer (Settings.Rotary)), Pres.Answer);
            Pres.Put_Field
              (Screen, "cli.inspect.label.rope_base",
               T.Image (Long_Float (Settings.Rope_Base), 1), Pres.Answer);

            --  What a reader of this report would otherwise have to work
            --  out from the architecture's name: which way it attends, and
            --  whether it can say what comes next at all. Both decide which
            --  command the file is for, and a caller who runs the wrong one
            --  learns it from a refusal rather than from here.
            Pres.Put_Field
              (Screen, "cli.inspect.label.attention",
               Screen.Message_Value
                 (if Settings.Causal
                  then "cli.inspect.value.one_way"
                  else "cli.inspect.value.both_ways"),
               Pres.Answer);
            Pres.Put_Field
              (Screen, "cli.inspect.label.output_head",
               Screen.Message_Value
                 (if Settings.Has_Head
                  then "cli.inspect.value.yes"
                  else "cli.inspect.value.no"),
               Pres.Answer);

            --  And the pooling the file states, for the file that states
            --  one. Absent and none are not the same answer, so a model
            --  that says nothing prints nothing here.
            if Settings.Pooling /= L.Pool_Unstated then
               Pres.Put_Field
                 (Screen, "cli.inspect.label.pooling",
                  (case Settings.Pooling is
                     when L.Pool_Mean => "mean",
                     when L.Pool_Last => "last",
                     when L.Pool_Cls  => "cls",
                     when others      => "none"),
                  Pres.Answer);
            end if;

            --  Tokenizer.
            declare
               Words : Vocab.Vocabulary;
               Kind  : E.Error_Info;
            begin
               Vocab.Load (Words, Container, Model_Bounds (Item), Kind);
               Pres.Put_Heading (Screen, "cli.inspect.heading.tokenizer", Pres.Answer, Gap => True);
               if E.Is_Error (Kind) then
                  Pres.Report (Screen, Kind);
               else
                  Pres.Put_Field
                    (Screen, "cli.inspect.label.tokenizer_model",
                     T.Escape_Controls (Vocab.Model_Name (Words)), Pres.Answer);
                  Pres.Put_Field
                    (Screen, "cli.inspect.label.vocabulary",
                     T.Image (Long_Long_Integer (Vocab.Size (Words))), Pres.Answer);
                  Pres.Put_Field
                    (Screen, "cli.inspect.label.byte_fallback",
                     Screen.Message_Value
                       (if Vocab.Has_Byte_Fallback (Words)
                        then "cli.inspect.value.yes"
                        else "cli.inspect.value.no"), Pres.Answer);
                  Pres.Put_Field
                    (Screen, "cli.inspect.label.bos_token",
                     T.Image (Long_Long_Integer (Vocab.Beginning_Token (Words))), Pres.Answer);
                  Pres.Put_Field
                    (Screen, "cli.inspect.label.eos_token",
                     T.Image (Long_Long_Integer (Vocab.End_Token (Words))), Pres.Answer);
                  Settings.Vocabulary := Vocab.Size (Words);
               end if;
               Vocab.Close (Words);
            end;

            --  Chat template: present and supported, present and outside the
            --  subset, or absent. Compiled and then rendered here, so the
            --  answer is evidence rather than a guess.
            --
            --  Compiling alone is not the evidence it looks like. A value
            --  this engine cannot compute is refused where it is read
            --  rather than where it is compiled -- which is what lets a
            --  template describing tool calling in a branch nobody enters
            --  be used for the conversations that do not enter it -- so a
            --  template that refuses on every conversation there is
            --  compiles without complaint. What is asked here is the
            --  question `run` asks: a turn, and a place for the model to
            --  answer.
            declare
               Text_Value : constant String :=
                 Containers.String_Value (Container, "tokenizer.chat_template");
               Compiled   : Model_Runner.Templates.Compiled;
               Outcome    : E.Error_Info;
            begin
               if Text_Value = "" then
                  Pres.Put_Field
                    (Screen, "cli.inspect.label.template",
                     Screen.Message_Value ("cli.inspect.value.absent"), Pres.Answer);
               else
                  Model_Runner.Templates.Compile
                    (Compiled, Text_Value, Model_Bounds (Item), Outcome);

                  if E.Is_Ok (Outcome) then
                     declare
                        Talk : Model_Runner.Conversation.History;
                        Room : String (1 .. 8192);
                        Used : Natural;
                     begin
                        Model_Runner.Conversation.Open (Talk, Status => Outcome);
                        if E.Is_Ok (Outcome) then
                           Model_Runner.Conversation.Append
                             (Talk, Model_Runner.Conversation.User_Role,
                              "Hello", Outcome);
                        end if;

                        if E.Is_Ok (Outcome) then
                           Model_Runner.Templates.Render
                             (Compiled, Talk,
                              Beginning_Token => "",
                              End_Token => "",
                              Add_Generation_Prompt => True,
                              Target => Room, Last => Used, Status => Outcome);
                        end if;

                        Model_Runner.Conversation.Close (Talk);
                     end;
                  end if;

                  Pres.Put_Field
                    (Screen, "cli.inspect.label.template",
                     Screen.Message_Value
                       (if E.Is_Ok (Outcome)
                        then "cli.inspect.value.present_supported"
                        else "cli.inspect.value.present_unsupported"), Pres.Answer,
                     (if E.Is_Ok (Outcome) then Pres.Good else Pres.Bad));
                  if E.Is_Error (Outcome) and then Item.Level = Opt.Verbose then
                     Pres.Report (Screen, Outcome);
                  end if;
                  Model_Runner.Templates.Close (Compiled);
               end if;
            end;

            --  Memory estimate for the requested context.
            declare
               Plan   : Model_Runner.Memory.Session_Plan;
               Detail2 : E.Error_Info;
            begin
               --  In the storage the caller named, so that what a session
               --  would take can be asked of each of them rather than only
               --  of the one this defaults to. A storage offered for what it
               --  saves should be able to say what it saves.
               L.Plan_For (Settings, Item.Context_Size, Plan, Detail2,
                           Cache => Item.Cache, Values => Item.Values);
               Pres.Put_Heading (Screen, "cli.inspect.heading.memory", Pres.Answer, Gap => True);
               Pres.Put_Field
                 (Screen, "cli.inspect.label.model_bytes",
                  Size_Said (Containers.Tensor_Data_Bytes (Container)), Pres.Answer);
               if E.Is_Ok (Detail2) then
                  Pres.Put_Field
                    (Screen, "cli.inspect.label.session_bytes",
                     Size_Said (Interfaces.Unsigned_64 (Plan.Total_Resident)),
                     Pres.Answer);
                  --  Whether that fits here: as the model list judges it,
                  --  two thirds of the machine's memory, the rest left for
                  --  everything else.
                  declare
                     Memory : constant Long_Long_Integer :=
                       Long_Long_Integer (Model_Runner.Platform.Physical_Memory);
                     Fits   : constant Boolean :=
                       Memory = 0 or else Long_Long_Integer (Plan.Total_Resident) <= Memory * 2 / 3;
                  begin
                     if Memory > 0 then
                        Pres.Put_Field
                          (Screen, "cli.inspect.label.fits",
                           Screen.Message_Value (if Fits then "cli.inspect.value.fits"
                                                 else "cli.inspect.value.too_big")
                           & " (" & Short_Size (Interfaces.Unsigned_64 (Memory)) & " here)",
                           Pres.Answer, (if Fits then Pres.Good else Pres.Bad));
                     end if;
                  end;
               end if;

               --  What --repack would need, which is the one number a caller
               --  weighing that flag has to have and could get only by trying
               --  it and watching. Every matrix becomes four bytes a weight;
               --  the vectors are decoded already and are not repacked.
               --  One line per mode, because the modes differ by a factor
               --  of two and the flag offers both: a caller who wants the
               --  exact one was being shown the price of the other.
               declare
                  Repacked : Interfaces.Unsigned_64 := 0;
                  Exact    : Interfaces.Unsigned_64 := 0;

                  --  And what the panel layout would need, which is a
                  --  different question with a much smaller answer: it
                  --  copies only the four-bit k-quant's matrices and the
                  --  copy is a fiftieth larger than what it copies, so a
                  --  file with none of that format reports the file itself.
                  Panels   : Interfaces.Unsigned_64 := 0;
               begin
                  --  A matrix already in the target format is not copied,
                  --  so a file that is binary32 throughout needs nothing --
                  --  which is what this said 9888 bytes for on a 5024-byte
                  --  fixture before the skip existed.
                  for Index in 1 .. Containers.Tensor_Count (Container) loop
                     if Containers.Tensor_Rank (Container, Index) >= 2 then
                        if not G."=" (Containers.Tensor_Format
                                        (Container, Index),
                                      G.Type_BF16)
                        then
                           Repacked := Repacked
                             + Containers.Tensor_Elements (Container, Index)
                               * 2;
                        end if;

                        if not G."=" (Containers.Tensor_Format
                                        (Container, Index),
                                      G.Type_F32)
                        then
                           Exact := Exact
                             + Containers.Tensor_Elements (Container, Index)
                               * 4;
                        end if;

                        --  Asked of the shape as well as the format,
                        --  because a row count that is not a whole number
                        --  of panels is left where it lies.
                        if Model_Runner.Quantization.Interleave.Interleaves
                             (Containers.Tensor_Format (Container, Index),
                              N.Element_Count
                                (Containers.Tensor_Elements (Container, Index)
                                 / Containers.Tensor_Dimension
                                     (Container, Index, 1)),
                              N.Element_Count
                                (Containers.Tensor_Dimension
                                   (Container, Index, 1)))
                        then
                           Panels := Panels
                             + Containers.Tensor_Elements (Container, Index)
                               / 256
                               * Interfaces.Unsigned_64
                                   (Model_Runner.Quantization.Interleave
                                      .Panel_Row_Bytes
                                        (Containers.Tensor_Format
                                           (Container, Index)));
                        end if;
                     end if;
                  end loop;

                  --  What must fit, not what is held afterwards. The copy
                  --  is decoded from the file's own bytes, so both exist at
                  --  once while it is being written; the file's are released
                  --  when it is done. A caller deciding whether --repack
                  --  will run needs the moment when both are there.
                  Pres.Put_Field
                    (Screen, "cli.inspect.label.repacked_exact",
                     Size_Said (Exact + Containers.Tensor_Data_Bytes (Container)),
                     Pres.Answer);
                  Pres.Put_Field
                    (Screen, "cli.inspect.label.repacked_bytes",
                     Size_Said (Repacked + Containers.Tensor_Data_Bytes (Container)),
                     Pres.Answer);
                  Pres.Put_Field
                    (Screen, "cli.inspect.label.repacked_rows",
                     Size_Said (Panels + Containers.Tensor_Data_Bytes (Container)),
                     Pres.Answer);
               end;
            end;
         end if;
      end;

      --  What would evaluate this model, which is not a property of the file
      --  but of the command that was typed. It is reported here because the
      --  answer stopped being obvious when a second backend arrived: --backend
      --  reference takes one worker whatever --threads says, and a caller who
      --  cannot see that has no way to tell a slow run from a wrong one.
      Pres.Put_Heading (Screen, "cli.inspect.heading.execution", Pres.Answer, Gap => True);
      Pres.Put_Field
        (Screen, "cli.inspect.label.backend",
         Model_Runner.Backend.Backend_Name (Item.Backend), Pres.Answer);
      Pres.Put_Field
        (Screen, "cli.inspect.label.workers",
         T.Image (Long_Long_Integer (Selected_Workers (Item))), Pres.Answer);

      --  Optional detail listings. Neither dumps a vocabulary by default.
      if Item.Show_Metadata then
         Pres.Put_Heading (Screen, "cli.inspect.heading.metadata", Pres.Answer, Gap => True);
         for Index in 1 .. Containers.Metadata_Count (Container) loop
            declare
               Key : constant String :=
                 Containers.Metadata_Key (Container, Index);
            begin
               Pres.Put_Data_Field
                 (Screen,
                  T.Escape_Controls (Key),
                  Containers.Value_Image (Container, Index), Pres.Answer);
            end;
         end loop;
      end if;

      if Item.Show_Tensors then
         Pres.Put_Heading (Screen, "cli.inspect.heading.tensors", Pres.Answer, Gap => True);
         for Index in 1 .. Containers.Tensor_Count (Container) loop
            declare
               Shape : String (1 .. 64) := [others => ' '];
               Last  : Natural := 0;
            begin
               for Axis in 1 .. Containers.Tensor_Rank (Container, Index) loop
                  declare
                     Piece : constant String :=
                       (if Axis > 1 then "x" else "")
                       & T.Image
                           (Long_Long_Integer
                              (Containers.Tensor_Dimension
                                 (Container, Index, Axis)));
                  begin
                     exit when Last + Piece'Length > Shape'Length;
                     Shape (Last + 1 .. Last + Piece'Length) := Piece;
                     Last := Last + Piece'Length;
                  end;
               end loop;

               Pres.Put_Field
                 (Screen,
                  "cli.inspect.label.name",
                  T.Escape_Controls
                    (Containers.Tensor_Name (Container, Index))
                  & "  " & Shape (1 .. Last)
                  & "  "
                  & G.Type_Name (Containers.Tensor_Format (Container, Index)), Pres.Answer);
            end;
         end loop;
      end if;

      L.Close (Prepared, Ignored);
      Containers.Close (Container);
      Shards.Close (Source);
      Status :=
        (if E.Is_Error (Refused) then E.Exit_Status (Refused)
         else E.Exit_Success);
   end Do_Inspect;

end Model_Runner.CLI.Execute.Inspect_Command;
