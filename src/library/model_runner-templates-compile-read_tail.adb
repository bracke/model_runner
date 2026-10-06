separate (Model_Runner.Templates.Compile)
procedure Read_Tail
  (Text   : String;
   From   : in out Natural;
   Result : in out Term) is
begin
   --  Methods written one after another: a template that cuts a reply
   --  at its reasoning marker and then trims what is left writes four
   --  in a row, and each takes what the one before it answered.
   loop
      declare
         Scan  : constant Natural := Skip_Spaces (Text, From);
         Doing : Method_Kind := Method_None;
         Ends  : Natural := 0;
         Taken : Boolean;

         --  Add a cut at a position, the position being an operand of
         --  its own: a template writes one worked out rather than
         --  written down.
         procedure Add_Cut
           (Source : String; Kind : Method_Kind; Added : out Boolean)
         is
            Where : Operand;
            Read  : Boolean;
            Scan_At : Natural := Source'First;
            Kept  : Natural;
         begin
            Added := False;
            Read_Operand (Source, Scan_At, Where, Read);
            if not Read
              or else Skip_Spaces (Source, Scan_At) <= Source'Last
              or else Result.Chained >= Max_Methods
            then
               return;
            end if;

            Keep (Where, Kept);
            if Kept = 0 then
               return;
            end if;

            Result.Chained := Result.Chained + 1;
            Result.Methods (Result.Chained) :=
              (Kind => Kind, At_Operand => Kept, Second_At => 0);
            Added := True;
         end Add_Cut;
      begin
         exit when Scan > Text'Last;

         --  A cut at a position: text[n:], text[:n] and text[a:b].
         --  Both ends are cut where both are written, and the far end
         --  first, because the near one moves what is left of the
         --  text and a position was counted in the text as it was.
         if Text (Scan) = '[' then
            declare
               Shut  : Natural := Scan + 1;
               Level : Natural := 0;
               Colon : Natural := 0;
            begin
               while Shut <= Text'Last loop
                  if Text (Shut) = '[' then
                     Level := Level + 1;
                  elsif Text (Shut) = ']' then
                     exit when Level = 0;
                     Level := Level - 1;
                  elsif Text (Shut) = ':' and then Level = 0
                    and then Colon = 0
                  then
                     Colon := Shut;
                  end if;
                  Shut := Shut + 1;
               end loop;

               exit when Shut > Text'Last;

               --  No colon: one element by position, of whatever
               --  came before -- a list, a cut, a text.
               if Colon = 0 then
                  declare
                     Added : Boolean;
                  begin
                     Add_Cut (Text (Scan + 1 .. Shut - 1), Method_Index,
                              Added);
                     if not Added then
                        Result := Refused (Text (Scan .. Shut));
                     end if;
                     From := Shut + 1;
                     goto Read_On;
                  end;
               end if;

               declare
                  Front : constant String :=
                    Model_Runner.Text.Trim (Text (Scan + 1 .. Colon - 1));
                  Back  : constant String :=
                    Model_Runner.Text.Trim (Text (Colon + 1 .. Shut - 1));
                  Added : Boolean := True;
               begin
                  if Back'Length > 0 then
                     Add_Cut (Back, Method_Cut_To, Added);
                  end if;

                  if Added and then Front'Length > 0 then
                     Add_Cut (Front, Method_Cut_From, Added);
                  end if;

                  if not Added then
                     Result := Refused (Text (Scan .. Shut));
                  end if;
               end;

               From := Shut + 1;
            end;

            goto Read_On;
         end if;

         exit when Text (Scan) /= '.';

         for Named of Method_Names loop
            if Doing = Method_None
              and then Scan + Named.Text.all'Length - 1 <= Text'Last
              and then Text (Scan .. Scan + Named.Text.all'Length - 1)
                       = Named.Text.all
            then
               Doing := Named.Kind;
               Ends := Scan + Named.Text.all'Length;
            end if;
         end loop;

         --  A dotted name that is not a method called: one member
         --  of what came before, which is how a path goes on after
         --  an index -- content[0].text.
         if Doing = Method_None
           or else Ends > Text'Last
           or else Text (Ends) /= '('
         then
            declare
               Stop : Natural := Scan + 1;
               Named : Operand;
               Kept  : Natural;
               Stored : Boolean;
            begin
               while Stop <= Text'Last
                 and then Text (Stop) in 'a' .. 'z' | 'A' .. 'Z'
                                         | '0' .. '9' | '_'
               loop
                  Stop := Stop + 1;
               end loop;
               exit when Stop = Scan + 1
                 or else (Stop <= Text'Last and then Text (Stop) = '(')
                 or else Result.Chained >= Max_Methods;

               Named.Count := 1;
               Named.Terms (1).Kind := Term_Literal;
               Store_Literal
                 (Text (Scan + 1 .. Stop - 1), Named.Terms (1).Offset,
                  Named.Terms (1).Length, Stored);
               exit when not Stored;
               Keep (Named, Kept);
               exit when Kept = 0;
               Result.Chained := Result.Chained + 1;
               Result.Methods (Result.Chained) :=
                 (Kind => Method_Member, At_Operand => Kept,
                  Second_At => 0);
               From := Stop;
               goto Read_On;
            end;
         end if;

         From := Ends;
         Add_Method (Text, Doing, From, Result, Taken);
         exit when not Taken;

         <<Read_On>>
         null;
      end;
   end loop;

   while Skip_Spaces (Text, From) <= Text'Last
     and then Text (Skip_Spaces (Text, From)) = '|'
   loop
      declare
         Scan        : Natural := Skip_Spaces (Text, From) + 1;
         First, Last : Natural;
      begin
         Read_Word (Text, Scan, First, Last);
         From := Scan;

         if Last < First or else Result.Filtered >= Max_Filters then
            Result := Refused ("filter", E.Template_Unknown_Filter);

         --  Which piece of a cut text is wanted. A template writes
         --  either text.split(marker)[0] or text.split(marker)|first,
         --  and the two are the same thing: the filter says which end
         --  the cut in front of it keeps, so it is answered by the
         --  cut rather than after it. Written after anything else it
         --  is a list this engine has not got.
         elsif Text (First .. Last) = "first"
           or else Text (First .. Last) = "last"
         then
            if Result.Chained > 0 and then Result.Filtered = 0
              and then Result.Methods (Result.Chained).Kind
                       in Method_Split_First | Method_Split_Last
                          | Method_Split_Whole
            then
               Result.Methods (Result.Chained).Kind :=
                 (if Text (First .. Last) = "first"
                  then Method_Split_First else Method_Split_Last);
            else
               --  One end of whatever list stands there.
               Result.Filtered := Result.Filtered + 1;
               Result.Filters (Result.Filtered) :=
                 (Kind => (if Text (First .. Last) = "first"
                           then Filter_First else Filter_Last),
                  others => <>);
            end if;

         else
            declare
               Word : constant String := Text (First .. Last);
               Step : Filter_Step;

               --  The arguments in brackets after a filter's name,
               --  each an operand, up to two: what default stands in
               --  and what replace takes out and puts in. tojson's
               --  ensure_ascii is taken and ignored, because every
               --  byte written here is UTF-8 already.
               --  Up to Wanted of them, Needed at least; a keyword
               --  argument goes to the slot the language's own order
               --  gives that keyword for this filter.
               procedure Read_Arguments
                 (Wanted : Natural; Needed : Natural := Natural'Last)
               is
                  Opens : constant Natural := Skip_Spaces (Text, From);
                  Shut  : Natural;

                  procedure Put_Argument (Slot : Natural; Kept : Natural)
                  is
                  begin
                     case Slot is
                        when 1 => Step.Arg1 := Kept;
                        when 2 => Step.Arg2 := Kept;
                        when others => Step.Arg3 := Kept;
                     end case;
                  end Put_Argument;

                  function Slot_Of_Keyword (Key : String) return Natural
                  is
                  begin
                     if Key = "attribute" then
                        return (if Word = "sort" then 3 else 1);
                     elsif Key = "reverse" then
                        return (if Word = "dictsort" then 3 else 1);
                     elsif Key = "case_sensitive" then
                        return (if Word = "dictsort" then 1 else 2);
                     elsif Key = "by" then
                        return 2;
                     elsif Key = "width" then
                        return 1;
                     elsif Key = "first" then
                        return 2;
                     elsif Key = "blank" then
                        return 3;
                     elsif Key = "d" or else Key = "default" then
                        return 1;
                     elsif Key = "indent" then
                        return 1;
                     elsif Key = "precision" or else Key = "linecount"
                       or else Key = "slices"
                     then
                        return 1;
                     elsif Key = "method" or else Key = "fill_with"
                       or else Key = "start" or else Key = "count"
                     then
                        return (if Key = "count" then 3 else 2);
                     elsif Key = "break_long_words" or else Key = "killwords"
                     then
                        return 2;
                     elsif Key = "wrapstring" or else Key = "end" then
                        return 3;
                     elsif Key = "leeway" then
                        return 3;
                     elsif Key = "ensure_ascii" or else Key = "sort_keys"
                     then
                        --  Taken and ignored: every byte written
                        --  here is UTF-8 already, and a mapping is
                        --  written in the order it holds.
                        return 2;
                     end if;
                     return 0;
                  end Slot_Of_Keyword;
               begin
                  if Opens > Text'Last or else Text (Opens) /= '(' then
                     if Wanted > 0
                       and then Natural'Min (Wanted, Needed) > 0
                     then
                        Result :=
                          Refused (Word, E.Template_Unknown_Filter);
                     end if;
                     return;
                  end if;

                  Shut := Closes_At (Text, Opens);
                  if Shut = 0 then
                     Result := Refused (Word, E.Template_Unknown_Filter);
                     return;
                  end if;

                  declare
                     Inside : constant String :=
                       Text (Opens + 1 .. Shut - 1);
                     Scan   : Natural := Inside'First;
                     Found  : Natural := 0;
                  begin
                     while Found < Wanted
                       and then Skip_Spaces (Inside, Scan) <= Inside'Last
                     loop
                        declare
                           Value : Operand;
                           Read  : Boolean;
                           Kept  : Natural;
                           Slot  : Natural := Found + 1;
                           Key_First, Key_Last : Natural;
                           Ahead : Natural := Scan;
                        begin
                           --  name=value: the slot is the keyword's.
                           Read_Word (Inside, Ahead, Key_First, Key_Last);
                           if Key_Last >= Key_First
                             and then Skip_Spaces (Inside, Ahead)
                                      <= Inside'Last
                             and then Inside (Skip_Spaces (Inside, Ahead))
                                      = '='
                             and then (Skip_Spaces (Inside, Ahead) + 1
                                       > Inside'Last
                                       or else Inside
                                                 (Skip_Spaces (Inside, Ahead)
                                                  + 1) /= '=')
                           then
                              Slot := Slot_Of_Keyword
                                        (Inside (Key_First .. Key_Last));
                              if Slot = 0 then
                                 Result :=
                                   Refused (Word, E.Template_Unknown_Filter);
                                 return;
                              end if;
                              Scan := Skip_Spaces (Inside, Ahead) + 1;
                           end if;

                           Read_Operand (Inside, Scan, Value, Read);
                           if not Read then
                              Result :=
                                Refused (Word, E.Template_Unknown_Filter);
                              return;
                           end if;
                           Keep (Value, Kept);
                           if Kept = 0 then
                              Result :=
                                Refused (Word, E.Template_Unknown_Filter);
                              return;
                           end if;
                           Found := Found + 1;
                           Put_Argument (Slot, Kept);
                        end;
                        Scan := Skip_Spaces (Inside, Scan);
                        if Scan <= Inside'Last then
                           if Inside (Scan) /= ',' then
                              Result :=
                                Refused (Word, E.Template_Unknown_Filter);
                              return;
                           end if;
                           Scan := Scan + 1;
                        end if;
                     end loop;
                     if Found < Natural'Min (Wanted, Needed) then
                        Result :=
                          Refused (Word, E.Template_Unknown_Filter);
                        return;
                     end if;
                  end;
                  From := Shut + 1;
               end Read_Arguments;
            begin
               if Word = "trim" then
                  Step.Kind := Filter_Trim;
                  Read_Arguments (1, 0);
               elsif Word = "length" then
                  Step.Kind := Filter_Length;
                  Result.Numeric := True;
               elsif Word = "tojson" then
                  Step.Kind := Filter_JSON;
                  Read_Arguments (2, 0);
               elsif Word = "params" then
                  Step.Kind := Filter_Params;
               elsif Word = "qwen_params" then
                  Step.Kind := Filter_Qwen_Params;
               elsif Word = "qwen_tool" then
                  Step.Kind := Filter_Qwen_Tool;
               elsif Word = "lower" then
                  Step.Kind := Filter_Lower;
               elsif Word = "upper" then
                  Step.Kind := Filter_Upper;
               elsif Word = "capitalize" then
                  Step.Kind := Filter_Capitalize;
               elsif Word = "title" then
                  Step.Kind := Filter_Title;
               elsif Word = "int" then
                  Step.Kind := Filter_Int;
                  Result.Numeric := True;
                  Read_Arguments (0);
               elsif Word = "float" then
                  Step.Kind := Filter_Float;
                  Result.Numeric := True;
                  Read_Arguments (0);
               elsif Word = "round" then
                  Step.Kind := Filter_Round;
                  Result.Numeric := True;
                  Read_Arguments (2, 0);
               elsif Word = "abs" then
                  Step.Kind := Filter_Abs;
                  Result.Numeric := True;
                  Read_Arguments (0);
               elsif Word = "sum" then
                  Step.Kind := Filter_Sum;
                  Result.Numeric := True;
                  Read_Arguments (2, 0);
               elsif Word = "count" then
                  Step.Kind := Filter_Length;
                  Result.Numeric := True;
               elsif Word = "urlencode" then
                  Step.Kind := Filter_Urlencode;
                  Read_Arguments (0);
               elsif Word = "batch" then
                  Step.Kind := Filter_Batch;
                  Read_Arguments (2, 1);
               elsif Word = "slice" then
                  Step.Kind := Filter_Slice;
                  Read_Arguments (2, 1);
               elsif Word = "groupby" then
                  Step.Kind := Filter_Groupby;
                  Read_Arguments (1, 1);
               elsif Word = "attr" then
                  Step.Kind := Filter_Attr;
                  Read_Arguments (1, 1);
               elsif Word = "wordwrap" then
                  Step.Kind := Filter_Wordwrap;
                  Read_Arguments (3, 0);
               elsif Word = "truncate" then
                  Step.Kind := Filter_Truncate;
                  Read_Arguments (3, 0);
               elsif Word = "center" then
                  Step.Kind := Filter_Center;
                  Read_Arguments (1, 0);
               elsif Word = "format" then
                  Step.Kind := Filter_Format;
                  Read_Arguments (3, 0);
               elsif Word = "striptags" then
                  Step.Kind := Filter_Striptags;
                  Read_Arguments (0);
               elsif Word = "pprint" then
                  Step.Kind := Filter_Pprint;
                  Read_Arguments (0);
               elsif Word = "random" then
                  Step.Kind := Filter_Random;
                  Read_Arguments (0);
               elsif Word = "reverse" then
                  Step.Kind := Filter_Reverse;
                  Read_Arguments (0);
               elsif Word = "max" then
                  Step.Kind := Filter_Max;
                  Read_Arguments (3, 0);
               elsif Word = "string" then
                  Step.Kind := Filter_String;
               elsif Word = "safe" then
                  Step.Kind := Filter_Safe;
               elsif Word = "default" or else Word = "d" then
                  --  The stand-in, and whether it stands in for any
                  --  value that is false rather than only for one
                  --  never set: default('', true).
                  Step.Kind := Filter_Default;
                  Read_Arguments (2, 1);
               elsif Word = "replace" then
                  Step.Kind := Filter_Replace;
                  Read_Arguments (3, 2);
               elsif Word = "min" then
                  Step.Kind := Filter_Min;
                  Result.Numeric := True;
               elsif Word = "join" then
                  Step.Kind := Filter_Join;
                  Read_Arguments (2, 0);
               elsif Word = "map" then
                  Step.Kind := Filter_Map;
                  Read_Arguments (1, 1);
               elsif Word = "select" then
                  Step.Kind := Filter_Select;
                  Read_Arguments (2, 0);
               elsif Word = "reject" then
                  Step.Kind := Filter_Reject;
                  Read_Arguments (2, 0);
               elsif Word = "selectattr" then
                  Step.Kind := Filter_Select_Attr;
                  Read_Arguments (3, 1);
               elsif Word = "rejectattr" then
                  Step.Kind := Filter_Reject_Attr;
                  Read_Arguments (3, 1);
               elsif Word = "sort" then
                  Step.Kind := Filter_Sort;
                  Read_Arguments (3, 0);
               elsif Word = "dictsort" then
                  Step.Kind := Filter_Dict_Sort;
                  Read_Arguments (3, 0);
               elsif Word = "indent" then
                  Step.Kind := Filter_Indent;
                  Read_Arguments (3, 0);
               elsif Word = "unique" then
                  Step.Kind := Filter_Unique;
                  Read_Arguments (0);
               elsif Word = "list" then
                  Step.Kind := Filter_List;
                  Read_Arguments (0);
               elsif Word = "items" then
                  --  A filter spelling of the method, and the same
                  --  thing: the mapping, to be walked entry by entry.
                  if Result.Chained < Max_Methods then
                     Result.Chained := Result.Chained + 1;
                     Result.Methods (Result.Chained) :=
                       (Kind => Method_Items, At_Operand => 0,
                        Second_At => 0);
                  end if;
                  Step.Kind := Filter_None;
               else
                  Result := Refused (Word, E.Template_Unknown_Filter);
               end if;

               if Result.Kind /= Term_Unsupported then
                  Result.Filtered := Result.Filtered + 1;
                  Result.Filters (Result.Filtered) := Step;
               end if;
            end;
         end if;
      end;
   end loop;
end Read_Tail;
