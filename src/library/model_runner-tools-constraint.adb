with Ada.Unchecked_Deallocation;

with Model_Runner.Schema;

package body Model_Runner.Tools.Constraint is

   package E renames Model_Runner.Errors;

   --  A grammar with no calls in it: the model was offered nothing, so its
   --  reply is prose and nothing follows it.
   Prose_Only : constant String :=
     "root ::= [^<]*" & ASCII.LF;

   --  The loose grammar's fixed part: the call envelope around a general
   --  JSON value, with the one hole -- the name rule -- filled from the
   --  tools offered. This is the fallback, used when a tool's argument
   --  schema cannot be turned into a grammar of its own; it still
   --  guarantees a readable call naming a tool on offer, only without
   --  pinning the argument shape. The quote and backslash are written as
   --  \x22 and \x5C throughout, to spare a reader counting backslashes
   --  through two layers of quoting.
   Loose_Fixed : constant String :=
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

   type Text_Access is access String;
   procedure Free is new Ada.Unchecked_Deallocation (String, Text_Access);

   --  A small decimal image, no leading space.
   function Image (Value : Positive) return String is
      Raw : constant String := Positive'Image (Value);
   begin
      return Raw (Raw'First + 1 .. Raw'Last);
   end Image;

   --  The index just past a JSON string whose opening quote is at Index.
   function After_String (Text : String; Index : Positive) return Positive is
      I : Natural := Index + 1;
   begin
      while I <= Text'Last loop
         if Text (I) = '\' then
            I := I + 2;
         elsif Text (I) = '"' then
            return I + 1;
         else
            I := I + 1;
         end if;
      end loop;
      return Text'Last + 1;
   end After_String;

   --  The "parameters" object of a tool definition: the slice from its
   --  opening brace to its closing one. Found is false when the definition
   --  names no parameters object -- a tool without arguments, or one this
   --  cannot read -- and the caller then falls back to the loose grammar.
   procedure Parameters_Of
     (Def   : String;
      First : out Natural;
      Last  : out Natural;
      Found : out Boolean)
   is
      Key : constant String := """parameters""";
      I   : Natural := Def'First;

      function White (C : Character) return Boolean
      is (C in ' ' | ASCII.HT | ASCII.LF | ASCII.CR);
   begin
      First := 0;
      Last  := 0;
      Found := False;

      while I + Key'Length - 1 <= Def'Last loop
         if Def (I .. I + Key'Length - 1) = Key then
            declare
               J : Natural := I + Key'Length;
            begin
               while J <= Def'Last and then White (Def (J)) loop
                  J := J + 1;
               end loop;
               if J <= Def'Last and then Def (J) = ':' then
                  J := J + 1;
                  while J <= Def'Last and then White (Def (J)) loop
                     J := J + 1;
                  end loop;
                  if J <= Def'Last and then Def (J) = '{' then
                     First := J;
                     declare
                        Depth : Natural := 0;
                     begin
                        while J <= Def'Last loop
                           case Def (J) is
                              when '"' =>
                                 J := After_String (Def, J);
                              when '{' =>
                                 Depth := Depth + 1;
                                 J := J + 1;
                              when '}' =>
                                 Depth := Depth - 1;
                                 J := J + 1;
                                 if Depth = 0 then
                                    Last  := J - 1;
                                    Found := True;
                                    return;
                                 end if;
                              when others =>
                                 J := J + 1;
                           end case;
                        end loop;
                     end;
                     return;   --  unbalanced; leave Found false
                  end if;
               end if;
            end;
         end if;
         I := I + 1;
      end loop;
   end Parameters_Of;

   ---------------------------------------------------------------------------
   --  Building the two grammars
   ---------------------------------------------------------------------------

   --  Append into a bounded buffer, noting an overflow rather than raising.
   type Builder is record
      Room : Text_Access;
      Used : Natural := 0;
      Full : Boolean := False;
   end record;

   procedure Put (B : in out Builder; Text : String) is
   begin
      if B.Full or else B.Used + Text'Length > B.Room'Length then
         B.Full := True;
         return;
      end if;
      B.Room (B.Room'First + B.Used .. B.Room'First + B.Used + Text'Length - 1)
        := Text;
      B.Used := B.Used + Text'Length;
   end Put;

   --  The shape of a call in each syntax: what opens it, what follows the
   --  name, what closes it, and the three spellings that make a parameter's
   --  tag. The JSON envelope has no tag spellings; its arguments are JSON.
   type Spelling is record
      Opens   : access constant String;
      Named   : access constant String;
      Closes  : access constant String;
      Before  : access constant String;
      After   : access constant String;
      Close   : access constant String;
   end record;

   Qwen_Opens  : aliased constant String := "<tool_call>"" ws ""<function=";
   Qwen_Named  : aliased constant String := ">";
   Qwen_Closes : aliased constant String :=
     "</function>"" ws ""</tool_call>";
   Qwen_Before : aliased constant String := "<parameter=";
   Qwen_After  : aliased constant String := ">";
   Qwen_Close  : aliased constant String := "</parameter>";

   Func_Opens  : aliased constant String := "<function name=\x22";
   Func_Named  : aliased constant String := "\x22>";
   Func_Closes : aliased constant String := "</function>";
   Func_Before : aliased constant String := "<param name=\x22";
   Func_After  : aliased constant String := "\x22>";
   Func_Close  : aliased constant String := "</param>";

   Qwen_Spelling : constant Spelling :=
     (Qwen_Opens'Access, Qwen_Named'Access, Qwen_Closes'Access,
      Qwen_Before'Access, Qwen_After'Access, Qwen_Close'Access);
   Func_Spelling : constant Spelling :=
     (Func_Opens'Access, Func_Named'Access, Func_Closes'Access,
      Func_Before'Access, Func_After'Access, Func_Close'Access);

   function In_Tags (Syntax : Call_Syntax) return Boolean
   is (Syntax in Qwen_XML | Function_XML);

   function Spelled (Syntax : Call_Syntax) return Spelling
   is (if Syntax = Qwen_XML then Qwen_Spelling else Func_Spelling);

   --  What may stand ahead of a reply in a tag syntax: the families that
   --  write one reason in a <think> block, and its '<' is one the prose
   --  rule refuses. Admitted once, at the start, closed before anything
   --  else; a reply with no reasoning writes none.
   Think_Rule : constant String :=
     "think ::= ""<think>"" [^<]* ""</think>"" ws" & ASCII.LF;

   --  The loose grammar for a tag syntax: the envelope around parameters
   --  named freely, each holding text. Names still constrained to the
   --  tools offered. The spellings of the tags are filled in per syntax.
   procedure Put_Loose_Tags (B : in out Builder; Sp : Spelling) is
   begin
      Put (B, "root ::= think? prose calls?" & ASCII.LF);
      Put (B, Think_Rule);
      Put (B, "prose ::= [^<]*" & ASCII.LF);
      Put (B, "calls ::= call ( ws call )*" & ASCII.LF);
      Put (B, "call ::= """ & Sp.Opens.all & """ name """ & Sp.Named.all
              & """ ws params """ & Sp.Closes.all & """" & ASCII.LF);
      Put (B, "params ::= ( """ & Sp.Before.all & """ pname """
              & Sp.After.all & """ text """ & Sp.Close.all & """ ws )*"
              & ASCII.LF);
      Put (B, "pname ::= [A-Za-z_] [A-Za-z0-9_.-]*" & ASCII.LF);
      Put (B, "text ::= [^<]*" & ASCII.LF);
      Put (B, "ws ::= [ \x09\x0A\x0D]*" & ASCII.LF);
   end Put_Loose_Tags;

   --  The loose grammar (§a): envelope + general JSON arguments, names
   --  constrained to those offered.
   procedure Build_Loose
     (Offered : Definitions; B : in out Builder; Syntax : Call_Syntax) is
   begin
      if In_Tags (Syntax) then
         Put_Loose_Tags (B, Spelled (Syntax));
      else
         Put (B, Loose_Fixed);
      end if;
      --  The names, quoted as JSON has them in the envelope and bare in a
      --  tag.
      Put (B, "name ::= ");
      for Index in 1 .. Count (Offered) loop
         if Index > 1 then
            Put (B, " | ");
         end if;
         if In_Tags (Syntax) then
            Put (B, """" & Tool_Name (Offered, Index) & """");
         else
            Put (B, """\x22" & Tool_Name (Offered, Index) & "\x22""");
         end if;
      end loop;
      Put (B, "" & ASCII.LF);
   end Build_Loose;

   --  The tight grammar (§b): each offered tool paired with a grammar for
   --  its own argument schema, so a call names a tool and its arguments
   --  match that tool's parameters. Ok is false when any tool's schema
   --  cannot be read or turned into a grammar, and the caller then builds
   --  the loose grammar instead.
   --  Given a Schema.To_Grammar output filling Text, the slice of its first
   --  line that follows "root ::= " -- the body every helper below leans on.
   --  Found is false when the output is not shaped "root ::= <body>".
   procedure Schema_Body
     (Text  : String;
      First : out Natural;
      Last  : out Natural;
      Found : out Boolean)
   is
      Head       : constant String := "root ::= ";
      Break      : Natural := Text'First;
      Body_First : constant Natural := Text'First + Head'Length;
   begin
      First := 0;
      Last  := 0;
      Found := False;
      while Break <= Text'Last and then Text (Break) /= ASCII.LF loop
         Break := Break + 1;
      end loop;
      if Break - 1 < Body_First
        or else Text'Length < Head'Length
        or else Text (Text'First .. Body_First - 1) /= Head
      then
         return;
      end if;
      First := Body_First;
      Last  := Break - 1;
      Found := True;
   end Schema_Body;

   procedure Build_Tight
     (Offered       : Definitions;
      Answer_Schema : String;
      Scratch       : Text_Access;
      B             : in out Builder;
      Ok            : out Boolean;
      Syntax        : Call_Syntax)
   is
      Count_Of     : constant Natural := Count (Offered);
      Typed_Answer : constant Boolean := Answer_Schema /= "";
      Tags         : constant Boolean := In_Tags (Syntax);
      Sp           : constant Spelling := Spelled (Syntax);
   begin
      Ok := True;

      --  Note: ws is not defined here. Each tool's schema grammar defines
      --  it (Model_Runner.Schema emits a shared ws rule), and those helpers
      --  are emitted once below; defining it here too would be a duplicate
      --  rule and refuse the grammar.
      if Typed_Answer then
         --  A reply is a call or the answer, in the shape asked for -- no
         --  free prose. The answer rule is defined after the tools, from the
         --  same shared helpers.
         Put (B, (if Tags then "root ::= think? (calls | answer)"
                  else "root ::= calls | answer") & ASCII.LF);
      else
         Put (B, (if Tags then "root ::= think? prose calls?"
                  else "root ::= prose calls?") & ASCII.LF);
         Put (B, "prose ::= [^<]*" & ASCII.LF);
      end if;
      if Tags then
         Put (B, Think_Rule);
      end if;
      Put (B, "calls ::= call ( ws call )*" & ASCII.LF);

      Put (B, "call ::= ");
      for Index in 1 .. Count_Of loop
         if Index > 1 then
            Put (B, " | ");
         end if;
         Put (B, "call_" & Image (Index));
      end loop;
      Put (B, "" & ASCII.LF);

      for Index in 1 .. Count_Of loop
         declare
            Def         : constant String := Definition (Offered, Index);
            First, Last : Natural;
            Present     : Boolean;
         begin
            Parameters_Of (Def, First, Last, Present);
            if not Present then
               Ok := False;
               return;
            end if;

            declare
               Grammar_Last : Natural;
               St           : E.Error_Info;
            begin
               if Tags then
                  Model_Runner.Schema.To_Tag_Grammar
                    (Def (First .. Last),
                     Sp.Before.all, Sp.After.all, Sp.Close.all,
                     Scratch.all, Grammar_Last, St);
               else
                  Model_Runner.Schema.To_Grammar
                    (Def (First .. Last), Scratch.all, Grammar_Last, St);
               end if;
               if E.Is_Error (St) or else Grammar_Last = 0 then
                  Ok := False;
                  return;
               end if;

               --  The schema grammar is "root ::= <body>" on the first line
               --  and its shared helper rules (str, num, int, ...) after it.
               --  Rename root to this tool's args rule and keep the body; the
               --  helpers are identical for every schema and are emitted once
               --  below, from the last tool read.
               declare
                  Text : String renames Scratch.all (1 .. Grammar_Last);
                  Break : Natural := Text'First;
               begin
                  while Break <= Text'Last
                    and then Text (Break) /= ASCII.LF
                  loop
                     Break := Break + 1;
                  end loop;

                  --  The body follows "root ::= ".
                  declare
                     Head : constant String := "root ::= ";
                     Body_First : constant Natural := Text'First + Head'Length;
                  begin
                     if Break - 1 < Body_First
                       or else Text (Text'First .. Body_First - 1) /= Head
                     then
                        Ok := False;
                        return;
                     end if;

                     if Tags then
                        Put (B, "call_" & Image (Index)
                             & " ::= """ & Sp.Opens.all
                             & Tool_Name (Offered, Index) & Sp.Named.all
                             & """ ws args_" & Image (Index)
                             & " """ & Sp.Closes.all & """" & ASCII.LF);
                     else
                        Put (B, "call_" & Image (Index)
                             & " ::= ""<tool_call>"" ws ""{"" ws "
                             & """\x22name\x22"" ws "":"" ws ""\x22"
                             & Tool_Name (Offered, Index)
                             & "\x22"" ws "","" ws ""\x22arguments\x22"" ws "
                             & """:"" ws args_" & Image (Index)
                             & " ws ""}"" ws ""</tool_call>""" & ASCII.LF);
                     end if;
                     Put (B, "args_" & Image (Index) & " ::= "
                          & Text (Body_First .. Break - 1) & ASCII.LF);

                     --  The shared helpers, once, taken from the last tool.
                     if Index = Count_Of and then Break < Text'Last then
                        Put (B, Text (Break + 1 .. Text'Last));
                     end if;
                  end;
               end;
            end;
         end;
      end loop;

      --  The answer rule, from the answer schema, sharing the helpers the
      --  tools above already emitted. Its own helpers are discarded; only
      --  its body becomes the answer.
      if Typed_Answer then
         declare
            Grammar_Last : Natural;
            St           : E.Error_Info;
         begin
            Model_Runner.Schema.To_Grammar
              (Answer_Schema, Scratch.all, Grammar_Last, St);
            if E.Is_Error (St) or else Grammar_Last = 0 then
               Ok := False;
               return;
            end if;
            declare
               Text        : String renames Scratch.all (1 .. Grammar_Last);
               First, Last : Natural;
               Found       : Boolean;
            begin
               Schema_Body (Text, First, Last, Found);
               if not Found then
                  Ok := False;
                  return;
               end if;
               Put (B, "answer ::= " & Text (First .. Last) & ASCII.LF);
            end;
         end;
      end if;

      if B.Full then
         Ok := False;
      end if;
   end Build_Tight;

   ------------------------
   -- Compile_Call_Grammar --
   ------------------------

   procedure Compile_Call_Grammar
     (Offered       : Model_Runner.Tools.Definitions;
      Into          : in out Model_Runner.Grammar.Compiled;
      Status        : out Model_Runner.Errors.Error_Info;
      Answer_Schema : String := "";
      Syntax        : Model_Runner.Tools.Call_Syntax :=
        Model_Runner.Tools.Tool_Call_JSON)
   is
      Tool_Count : constant Natural := Count (Offered);
   begin
      if Tool_Count = 0 then
         if Answer_Schema = "" then
            Model_Runner.Grammar.Compile (Into, Prose_Only, Status);
            return;
         end if;

         --  No tools, but an answer to shape: the whole reply is that
         --  answer, so the schema grammar stands on its own. A schema that
         --  will not compile falls back to prose rather than failing.
         declare
            Scratch : Text_Access :=
              new String (1 .. Model_Runner.Schema.Max_Grammar_Bytes);
            Last    : Natural;
            St      : E.Error_Info;
         begin
            Model_Runner.Schema.To_Grammar
              (Answer_Schema, Scratch.all, Last, St);
            if E.Is_Error (St) or else Last = 0 then
               Model_Runner.Grammar.Compile (Into, Prose_Only, Status);
            else
               Model_Runner.Grammar.Compile
                 (Into, Scratch.all (1 .. Last), Status);
               if E.Is_Error (Status) then
                  Model_Runner.Grammar.Compile (Into, Prose_Only, Status);
               end if;
            end if;
            Free (Scratch);
         end;
         return;
      end if;

      declare
         Scratch : Text_Access :=
           new String (1 .. Model_Runner.Schema.Max_Grammar_Bytes);
         Tight   : Builder :=
           (Room => new String (1 .. 256 * 1024), others => <>);
         Loose   : Builder :=
           (Room => new String (1 .. Loose_Fixed'Length + 32 * 1024),
            others => <>);
         Ok      : Boolean;
      begin
         --  Try the tight grammar first; fall back to the loose one when a
         --  tool's schema cannot be read or the result will not compile. The
         --  answer schema is honoured only on the tight path; the loose
         --  fallback leaves the answer as free text.
         Build_Tight (Offered, Answer_Schema, Scratch, Tight, Ok, Syntax);
         if Ok then
            Model_Runner.Grammar.Compile
              (Into, Tight.Room (1 .. Tight.Used), Status);
            if E.Is_Ok (Status) then
               Free (Scratch);
               Free (Tight.Room);
               Free (Loose.Room);
               return;
            end if;
         end if;

         Build_Loose (Offered, Loose, Syntax);
         if Loose.Full then
            Status := E.Make (E.Tools_Too_Large);
         else
            Model_Runner.Grammar.Compile
              (Into, Loose.Room (1 .. Loose.Used), Status);
         end if;

         Free (Scratch);
         Free (Tight.Room);
         Free (Loose.Room);
      end;
   end Compile_Call_Grammar;

end Model_Runner.Tools.Constraint;
