package body Model_Runner.Tools.Constraint is

   package E renames Model_Runner.Errors;

   --  The fixed part of the grammar. A JSON value in full, wrapped in the
   --  call envelope, with the one hole -- the name rule -- filled from the
   --  tools offered. The quote and the backslash are written as \x22 and
   --  \x5C throughout rather than as escaped quotes, so that a reader is
   --  spared counting backslashes through two layers of quoting.
   Fixed : constant String :=
     "root ::= prose calls?" & ASCII.LF &
     "prose ::= [^<]*" & ASCII.LF &
     "calls ::= call ( ws call )*" & ASCII.LF &
     "call ::= ""<tool_call>"" ws obj ws ""</tool_call>""" & ASCII.LF &
     "obj ::= ""{"" ws ""\x22name\x22"" ws "":"" ws name ws "","" ws "
       & """\x22arguments\x22"" ws "":"" ws value ws ""}""" & ASCII.LF &
     "value ::= object | array | string | number | ""true"" | ""false"" "
       & "| ""null""" & ASCII.LF &
     "object ::= ""{"" ws ( member ( ws "","" ws member )* )? ws ""}""" &
       ASCII.LF &
     "member ::= string ws "":"" ws value" & ASCII.LF &
     "array ::= ""["" ws ( value ( ws "","" ws value )* )? ws ""]""" &
       ASCII.LF &
     "string ::= ""\x22"" char* ""\x22""" & ASCII.LF &
     "char ::= [^\x22\x5C] | escaped" & ASCII.LF &
     "escaped ::= ""\x5C"" ( ""\x22"" | ""\x5C"" | ""/"" | ""b"" | ""f"" "
       & "| ""n"" | ""r"" | ""t"" | uesc )" & ASCII.LF &
     "uesc ::= ""u"" hex hex hex hex" & ASCII.LF &
     "hex ::= [0-9a-fA-F]" & ASCII.LF &
     "number ::= ""-""? intp fracp? expp?" & ASCII.LF &
     "intp ::= ""0"" | [1-9] [0-9]*" & ASCII.LF &
     "fracp ::= ""."" [0-9]+" & ASCII.LF &
     "expp ::= [eE] [+-]? [0-9]+" & ASCII.LF &
     "ws ::= [ \x09\x0A\x0D]*" & ASCII.LF;

   --  A grammar with no calls in it: the model was offered nothing, so its
   --  reply is prose and nothing follows it.
   Prose_Only : constant String :=
     "root ::= [^<]*" & ASCII.LF;

   ------------------------
   -- Compile_Call_Grammar --
   ------------------------

   procedure Compile_Call_Grammar
     (Offered : Model_Runner.Tools.Definitions;
      Into    : in out Model_Runner.Grammar.Compiled;
      Status  : out Model_Runner.Errors.Error_Info)
   is
      Tool_Count : constant Natural := Model_Runner.Tools.Count (Offered);
   begin
      if Tool_Count = 0 then
         Model_Runner.Grammar.Compile (Into, Prose_Only, Status);
         return;
      end if;

      declare
         --  The fixed part, then one name rule listing the offered names as
         --  alternatives. Generous room: sixty-four names of a few bytes
         --  each is a kilobyte beside this.
         Room : String (1 .. Fixed'Length + 32 * 1024);
         Used : Natural := 0;
         Full : Boolean := False;

         procedure Put (Text : String) is
         begin
            if Full or else Used + Text'Length > Room'Length then
               Full := True;
               return;
            end if;
            Room (Used + 1 .. Used + Text'Length) := Text;
            Used := Used + Text'Length;
         end Put;
      begin
         Put (Fixed);
         Put ("name ::= ");
         for Index in 1 .. Tool_Count loop
            if Index > 1 then
               Put (" | ");
            end if;
            --  Each name as the literal quote-name-quote the JSON object
            --  carries. A name is an identifier the definitions named, so
            --  it has no quote or backslash of its own to escape.
            Put ("""\x22" & Model_Runner.Tools.Tool_Name (Offered, Index)
                 & "\x22""");
         end loop;
         Put ("" & ASCII.LF);

         if Full then
            Status := E.Make (E.Tools_Too_Large);
            return;
         end if;

         Model_Runner.Grammar.Compile (Into, Room (1 .. Used), Status);
      end;
   end Compile_Call_Grammar;

end Model_Runner.Tools.Constraint;
