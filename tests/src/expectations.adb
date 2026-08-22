with Ada.Directories;
with Ada.Text_IO;

with Model_Runner.Text;

package body Expectations is

   --  The escape introducer used by the greedy_text directive.
   ESCAPE : constant Character := Character'Val (92);

   package T renames Model_Runner.Text;

   ----------
   -- Load --
   ----------

   procedure Load (Path : String; Item : out Recording) is
      Handle : Ada.Text_IO.File_Type;

      procedure Reject (Detail : String) is
         Room : constant Natural :=
           Natural'Min (Detail'Length, Item.Problem'Length);
      begin
         Item.Valid := False;
         Item.Problem (1 .. Room) :=
           Detail (Detail'First .. Detail'First + Room - 1);
         Item.Problem_Last := Room;
      end Reject;

      --  Store text in a fixed field.
      procedure Store
        (Target : out String;
         Last   : out Natural;
         Value  : String)
      is
         Room : constant Natural := Natural'Min (Value'Length, Target'Length);
      begin
         Target := [others => ' '];
         Target (Target'First .. Target'First + Room - 1) :=
           Value (Value'First .. Value'First + Room - 1);
         Last := Room;
      end Store;

      --  Read a whitespace-separated list of integers.
      procedure Read_Tokens
        (Value  : String;
         Target : out Token_List;
         Used   : out Natural;
         Ok     : out Boolean)
      is
         First : Natural := Value'First;
      begin
         Target := [others => 0];
         Used := 0;
         Ok := True;

         while First <= Value'Last loop
            while First <= Value'Last and then Value (First) = ' ' loop
               First := First + 1;
            end loop;
            exit when First > Value'Last;

            declare
               Last : Natural := First;
            begin
               while Last <= Value'Last and then Value (Last) /= ' ' loop
                  Last := Last + 1;
               end loop;

               if Used >= Target'Length then
                  Ok := False;
                  return;
               end if;

               begin
                  Used := Used + 1;
                  Target (Used) := Integer'Value (Value (First .. Last - 1));
               exception
                  when others =>
                     Ok := False;
                     return;
               end;

               First := Last;
            end;
         end loop;
      end Read_Tokens;

   begin
      Item := (others => <>);

      if Path = "" or else not Ada.Directories.Exists (Path) then
         Reject ("no expectation file at " & Path);
         return;
      end if;

      Ada.Text_IO.Open (Handle, Ada.Text_IO.In_File, Path);

      while not Ada.Text_IO.End_Of_File (Handle) loop
         declare
            Line : constant String := T.Trim (Ada.Text_IO.Get_Line (Handle));
         begin
            if Line'Length = 0 or else Line (Line'First) = '#' then
               null;

            else
               declare
                  Split : Natural := Line'First;
               begin
                  while Split <= Line'Last and then Line (Split) /= ' ' loop
                     Split := Split + 1;
                  end loop;

                  declare
                     Name  : constant String := Line (Line'First .. Split - 1);
                     Value : constant String :=
                       (if Split >= Line'Last then ""
                        else T.Trim (Line (Split + 1 .. Line'Last)));
                     Ok    : Boolean;
                  begin
                     if Name = "runtime" then
                        Store (Item.Runtime, Item.Runtime_Last, Value);

                     elsif Name = "model" then
                        Store (Item.Model, Item.Model_Last, Value);

                     elsif Name = "prompt" then
                        Store (Item.Prompt, Item.Prompt_Last, Value);

                     elsif Name = "tokens" then
                        Read_Tokens (Value, Item.Tokens, Item.Tokens_Used, Ok);
                        if not Ok then
                           Ada.Text_IO.Close (Handle);
                           Reject ("malformed tokens directive");
                           return;
                        end if;
                        Item.Has_Tokens := True;

                     elsif Name = "greedy" then
                        Read_Tokens (Value, Item.Greedy, Item.Greedy_Used, Ok);
                        if not Ok then
                           Ada.Text_IO.Close (Handle);
                           Reject ("malformed greedy directive");
                           return;
                        end if;
                        Item.Has_Greedy := True;

                     elsif Name = "greedy_text" then
                        --  Escapes are decoded here so that a recording can
                        --  carry a multi-line continuation on one line.
                        declare
                           Decoded : String (1 .. Value'Length);
                           Filled  : Natural := 0;
                           Index   : Natural := Value'First;
                        begin
                           while Index <= Value'Last loop
                              if Value (Index) = ESCAPE
                                and then Index < Value'Last
                              then
                                 Index := Index + 1;
                                 Filled := Filled + 1;
                                 case Value (Index) is
                                    when 'n'    => Decoded (Filled) := ASCII.LF;
                                    when 't'    => Decoded (Filled) := ASCII.HT;
                                    when 'r'    => Decoded (Filled) := ASCII.CR;
                                    when 's'    => Decoded (Filled) := ' ';
                                    when others => Decoded (Filled) := Value (Index);
                                 end case;
                              else
                                 Filled := Filled + 1;
                                 Decoded (Filled) := Value (Index);
                              end if;
                              Index := Index + 1;
                           end loop;

                           Store (Item.Greedy_Text, Item.Greedy_Last,
                                  Decoded (1 .. Filled));
                           Item.Has_Text := True;
                        end;

                     elsif Name = "logit" then
                        declare
                           Space : Natural := Value'First;
                        begin
                           while Space <= Value'Last
                             and then Value (Space) /= ' '
                           loop
                              Space := Space + 1;
                           end loop;

                           if Space > Value'Last
                             or else Item.Logits_Used >= Item.Logits'Length
                           then
                              Ada.Text_IO.Close (Handle);
                              Reject ("malformed logit directive");
                              return;
                           end if;

                           Item.Logits_Used := Item.Logits_Used + 1;
                           Item.Logits (Item.Logits_Used) :=
                             (Index => Natural'Value (Value (Value'First .. Space - 1)),
                              Value =>
                                Long_Float'Value
                                  (T.Trim (Value (Space + 1 .. Value'Last))));
                        exception
                           when others =>
                              Ada.Text_IO.Close (Handle);
                              Reject ("malformed logit directive");
                              return;
                        end;

                     elsif Name = "embd" then
                        --  Recorded in order and stored by the index the
                        --  file names, so a file that skips one or writes
                        --  them out of order is refused rather than read as
                        --  a shorter vector.
                        declare
                           Space : Natural := Value'First;
                        begin
                           while Space <= Value'Last
                             and then Value (Space) /= ' '
                           loop
                              Space := Space + 1;
                           end loop;

                           if Space > Value'Last
                             or else Item.Embedding_Used
                                     >= Item.Embedding'Length
                           then
                              Ada.Text_IO.Close (Handle);
                              Reject ("malformed embd directive");
                              return;
                           end if;

                           if Natural'Value (Value (Value'First .. Space - 1))
                              /= Item.Embedding_Used
                           then
                              Ada.Text_IO.Close (Handle);
                              Reject ("an embd index is out of order");
                              return;
                           end if;

                           Item.Embedding_Used := Item.Embedding_Used + 1;
                           Item.Embedding (Item.Embedding_Used) :=
                             Long_Float'Value
                               (T.Trim (Value (Space + 1 .. Value'Last)));
                           Item.Has_Embedding := True;
                        exception
                           when others =>
                              Ada.Text_IO.Close (Handle);
                              Reject ("malformed embd directive");
                              return;
                        end;

                     elsif Name = "pooling" then
                        declare
                           Named : constant String := T.Trim (Value);
                        begin
                           if Named = "mean" then
                              Item.Pooling := Pool_Mean;
                           elsif Named = "cls" then
                              Item.Pooling := Pool_Cls;
                           elsif Named = "last" then
                              Item.Pooling := Pool_Last;
                           else
                              Ada.Text_IO.Close (Handle);
                              Reject ("unknown pooling: " & Named);
                              return;
                           end if;
                        end;

                     elsif Name = "tolerance" then
                        begin
                           Item.Tolerance := Long_Float'Value (Value);
                        exception
                           when others =>
                              Ada.Text_IO.Close (Handle);
                              Reject ("malformed tolerance directive");
                              return;
                        end;

                     else
                        Ada.Text_IO.Close (Handle);
                        Reject ("unknown directive: " & Name);
                        return;
                     end if;
                  end;
               end;
            end if;
         end;
      end loop;

      Ada.Text_IO.Close (Handle);

      --  Provenance is not optional: an expectation whose origin is not
      --  recorded cannot be treated as evidence of anything.
      if Item.Runtime_Last = 0 then
         Reject ("no runtime directive: the origin of these values is unrecorded");
         return;
      end if;

      if Item.Model_Last = 0 then
         Reject ("no model directive: which model these values came from is"
                 & " unrecorded");
         return;
      end if;

      if not Item.Has_Tokens and then not Item.Has_Greedy
        and then not Item.Has_Text and then Item.Logits_Used = 0
        and then not Item.Has_Embedding
      then
         Reject ("the file records nothing to compare against");
         return;
      end if;

      Item.Valid := True;
   exception
      when others =>
         if Ada.Text_IO.Is_Open (Handle) then
            Ada.Text_IO.Close (Handle);
         end if;
         Reject ("the expectation file could not be read");
   end Load;

end Expectations;
