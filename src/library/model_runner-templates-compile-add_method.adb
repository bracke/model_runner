separate (Model_Runner.Templates.Compile)
procedure Add_Method
  (Text   : String;
   Doing  : Method_Kind;
   From   : in out Natural;
   Result : in out Term;
   Ok     : out Boolean)
is
   Scan  : Natural := Skip_Spaces (Text, From);
   Taken : Boolean;
   Kept  : Natural := 0;
   Second : Natural := 0;
   Third  : Natural := 0;
   Piece : Operand;
   Doing_Now : Method_Kind := Doing;

   --  Whether a cut was told to make two pieces at most.
   Once : Boolean := False;
begin
   Ok := False;

   if Scan > Text'Last or else Text (Scan) /= '(' then
      return;
   end if;

   --  The argument, which is a piece of text or nothing at all: strip
   --  with no argument takes whitespace off, as the language says.
   --  replace takes two, the second after a comma.
   Scan := Skip_Spaces (Text, Scan + 1);

   --  str.format accepts positional and named fields. Keep up to three
   --  value operands and, for a named one, a literal operand carrying its
   --  key. This covers the named placeholders used by current model
   --  templates without evaluating Python's full formatting mini-language.
   if Doing = Method_Format then
      declare
         Values : array (1 .. 3) of Natural := [others => 0];
         Keys   : array (1 .. 3) of Natural := [others => 0];
         Count  : Natural := 0;
      begin
         while Scan <= Text'Last and then Text (Scan) /= ')' loop
            if Count = Values'Last then
               return;
            end if;
            Count := Count + 1;
            declare
               Probe : Natural := Scan;
               KF, KL : Natural;
               Equals : Natural;
               Named : Boolean := False;
            begin
               Read_Word (Text, Probe, KF, KL);
               Equals := Skip_Spaces (Text, Probe);
               if KL >= KF and then Is_Plain_Name (Text (KF .. KL))
                 and then Equals <= Text'Last and then Text (Equals) = '='
                 and then (Equals = Text'Last or else Text (Equals + 1) /= '=')
               then
                  declare
                     Key : Operand;
                     Stored : Boolean;
                  begin
                     Key.Count := 1;
                     Key.Terms (1).Kind := Term_Literal;
                     Store_Literal
                       (Text (KF .. KL), Key.Terms (1).Offset,
                        Key.Terms (1).Length, Stored);
                     if not Stored then
                        return;
                     end if;
                     Keep (Key, Keys (Count));
                     if Keys (Count) = 0 then
                        return;
                     end if;
                  end;
                  Scan := Equals + 1;
                  Named := True;
               end if;

               Read_Operand (Text, Scan, Piece, Taken);
               if not Taken then
                  return;
               end if;
               Keep (Piece, Values (Count));
               if Values (Count) = 0 then
                  return;
               end if;
               Scan := Skip_Spaces (Text, Scan);
               if Scan <= Text'Last and then Text (Scan) = ',' then
                  Scan := Skip_Spaces (Text, Scan + 1);
               elsif Scan <= Text'Last and then Text (Scan) /= ')' then
                  return;
               end if;
               pragma Unreferenced (Named);
            end;
         end loop;

         if Scan > Text'Last or else Text (Scan) /= ')'
           or else Result.Chained >= Max_Methods
         then
            return;
         end if;
         Result.Chained := Result.Chained + 1;
         Result.Methods (Result.Chained) :=
           (Kind => Method_Format,
            At_Operand => Values (1), Second_At => Values (2),
            Third_At => Values (3), First_Key_At => Keys (1),
            Second_Key_At => Keys (2), Third_Key_At => Keys (3));
         From := Scan + 1;
         Ok := True;
         return;
      end;
   end if;

   if Scan <= Text'Last and then Text (Scan) /= ')' then
      Read_Operand (Text, Scan, Piece, Taken);
      if not Taken then
         return;
      end if;
      Keep (Piece, Kept);
      if Kept = 0 then
         return;
      end if;
      Scan := Skip_Spaces (Text, Scan);

      --  A cut's count of pieces, where it is one: split(marker, 1)
      --  cuts at the first marker alone. Any other count is a list
      --  this engine has no spelling for.
      if Doing in Method_Split_First | Method_Right_Split
        and then Scan <= Text'Last
        and then Text (Scan) = ','
      then
         Scan := Skip_Spaces (Text, Scan + 1);
         if Scan > Text'Last or else Text (Scan) /= '1' then
            return;
         end if;
         Once := True;
         Scan := Skip_Spaces (Text, Scan + 1);
      end if;

      if Doing in Method_Replace | Method_Get | Method_Format
        and then Scan <= Text'Last
        and then Text (Scan) = ','
      then
         declare
            Other : Operand;
         begin
            Scan := Scan + 1;
            Read_Operand (Text, Scan, Other, Taken);
            if not Taken then
               return;
            end if;
            Keep (Other, Second);
            if Second = 0 then
               return;
            end if;
            Scan := Skip_Spaces (Text, Scan);
         end;
      end if;

      if Doing = Method_Replace and then Scan <= Text'Last
        and then Text (Scan) = ','
      then
         declare
            Other : Operand;
         begin
            Scan := Scan + 1;
            Read_Operand (Text, Scan, Other, Taken);
            if not Taken then
               return;
            end if;
            Keep (Other, Third);
            if Third = 0 then
               return;
            end if;
            Scan := Skip_Spaces (Text, Scan);
         end;
      end if;
   end if;

   if Scan > Text'Last or else Text (Scan) /= ')' then
      return;
   end if;

   --  A cut with nothing in its brackets cuts at every run of white
   --  space, which is not a marker this engine cuts at: refused, as an
   --  unreadable method is, rather than cut at the four characters a
   --  strip takes off.
   if Doing in Method_Split_First | Method_Right_Split and then Kept = 0 then
      Result := Refused (Text (From .. Scan));
      From := Scan + 1;
      Ok := True;
      return;
   end if;
   Scan := Scan + 1;

   --  A cut answers with a list, and a template takes one side of it.
   --  Only the two ends are read, because only the two ends are what a
   --  template asks for: what came before the marker, or what came
   --  after the last one. Which end is said either by a position
   --  written after the cut or by a filter written after it, and a
   --  cut that says neither is left unresolved rather than guessed:
   --  it refuses if it is ever read.
   if Doing = Method_Right_Split and then Once then
      if Scan + 2 <= Text'Last and then Text (Scan .. Scan + 2) = "[0]"
      then
         Doing_Now := Method_Right_Split_Once_Before;
         Scan := Scan + 3;
      elsif Scan + 2 <= Text'Last
        and then Text (Scan .. Scan + 2) = "[1]"
      then
         Doing_Now := Method_Split_Last;
         Scan := Scan + 3;
      elsif Scan + 3 <= Text'Last
        and then Text (Scan .. Scan + 3) = "[-1]"
      then
         Doing_Now := Method_Split_Last;
         Scan := Scan + 4;
      else
         Doing_Now := Method_Split_Whole;
      end if;
   elsif Doing = Method_Right_Split then
      if Scan + 2 <= Text'Last and then Text (Scan .. Scan + 2) = "[0]"
      then
         Doing_Now := Method_Split_First;
         Scan := Scan + 3;
      elsif Scan + 3 <= Text'Last
        and then Text (Scan .. Scan + 3) = "[-1]"
      then
         Doing_Now := Method_Split_Last;
         Scan := Scan + 4;
      else
         Doing_Now := Method_Split_Whole;
      end if;
   elsif Doing = Method_Split_First and then Once then
      --  Two pieces at most: the one before the first marker and the
      --  rest, and a template takes one of them by position.
      if Scan + 2 <= Text'Last and then Text (Scan .. Scan + 2) = "[0]"
      then
         Scan := Scan + 3;
      elsif Scan + 2 <= Text'Last
        and then Text (Scan .. Scan + 2) = "[1]"
      then
         Doing_Now := Method_Split_Once_After;
         Scan := Scan + 3;
      elsif Scan + 3 <= Text'Last
        and then Text (Scan .. Scan + 3) = "[-1]"
      then
         Doing_Now := Method_Split_Once_Rest;
         Scan := Scan + 4;
      else
         Doing_Now := Method_Split_Whole;
      end if;
   elsif Doing = Method_Split_First then
      if Scan + 2 <= Text'Last and then Text (Scan .. Scan + 2) = "[0]"
      then
         Scan := Scan + 3;
      elsif Scan + 3 <= Text'Last
        and then Text (Scan .. Scan + 3) = "[-1]"
      then
         Doing_Now := Method_Split_Last;
         Scan := Scan + 4;
      else
         Doing_Now := Method_Split_Whole;
      end if;
   end if;

   if Result.Chained >= Max_Methods then
      Result := Refused ("method chain");
      From := Scan;
      Ok := True;
      return;
   end if;

   Result.Chained := Result.Chained + 1;
   Result.Methods (Result.Chained) :=
     (Kind => Doing_Now, At_Operand => Kept, Second_At => Second,
      Third_At => Third, First_Key_At => 0, Second_Key_At => 0,
      Third_Key_At => 0);
   From := Scan;
   Ok := True;
end Add_Method;
