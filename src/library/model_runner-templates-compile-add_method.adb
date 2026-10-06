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
      if Doing = Method_Split_First and then Scan <= Text'Last
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
   end if;

   if Scan > Text'Last or else Text (Scan) /= ')' then
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
   if Doing = Method_Split_First and then Once then
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
     (Kind => Doing_Now, At_Operand => Kept, Second_At => Second);
   From := Scan;
   Ok := True;
end Add_Method;
